import Foundation

/// The app's end of the socket: listens, accepts one engine at a time, checks
/// its token, sends it its settings, then passes events up and commands down.
public final class EngineLink: @unchecked Sendable {
    public enum LinkError: Error { case socket(String) }

    public let path: String
    private let queue = DispatchQueue(label: "friday.link")
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var buffer = LineBuffer()
    private var token = ""
    private var settings: [String: String] = [:]
    private var verified = false

    /// Called on the link's queue.
    public var onEvent: ((EngineEvent) -> Void)?
    /// The engine connected and passed the token check.
    public var onConnect: ((Int32) -> Void)?
    public var onDisconnect: (() -> Void)?

    public init(path: String) { self.path = path }

    /// Create the socket (mode 0600, in a 0700 folder) and start listening.
    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw LinkError.socket("socket: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw LinkError.socket("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0 else { throw LinkError.socket("bind: \(errno)") }
        chmod(path, 0o600)
        guard listen(listener, 2) == 0 else { throw LinkError.socket("listen: \(errno)") }

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
    }

    /// The token the next engine must present, and the settings it will be sent.
    public func expect(token: String, settings: [String: String]) {
        queue.sync { self.token = token; self.settings = settings }
    }

    public func send(_ command: HostCommand) {
        queue.async { [self] in
            guard client >= 0, verified else { return }
            write(command.encode())
        }
    }

    public func stop() {
        queue.sync {
            dropClient(notify: false)
            acceptSource?.cancel(); acceptSource = nil
            if listener >= 0 { close(listener); listener = -1 }
            unlink(path)
        }
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        dropClient(notify: false)  // one engine at a time: the newest wins
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        client = fd
        verified = false
        buffer = LineBuffer()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(from: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        readSource = source
    }

    private func read(from fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else { dropClient(notify: true); return }
        for line in buffer.append(Data(chunk[0..<count])) {
            guard let event = EngineEvent.decode(line) else { continue }
            if !verified {
                // The first message must be a hello with this launch's token.
                guard case .hello(let presented, let pid, _) = event, !token.isEmpty, presented == token else {
                    dropClient(notify: false)
                    return
                }
                verified = true
                write(HostCommand.configure(settings).encode())
                onConnect?(pid)
            }
            onEvent?(event)
        }
    }

    private func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(client, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func dropClient(notify: Bool) {
        guard client >= 0 else { return }
        let wasVerified = verified
        readSource?.cancel(); readSource = nil
        client = -1
        verified = false
        if notify && wasVerified { onDisconnect?() }
    }
}
