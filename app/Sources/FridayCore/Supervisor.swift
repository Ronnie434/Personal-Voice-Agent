import Foundation

/// How to start the engine.
public struct EngineLaunch: Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], directory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }
}

/// Keeps one engine running: starts it, checks it in over the socket, watches
/// its heartbeat, restarts it when it dies, and stops trying when it keeps dying.
public final class Supervisor: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case stopped, starting, running, restarting(in: TimeInterval), failed(String)
    }

    /// No heartbeat for this long means the engine is stuck.
    public static let heartbeatTimeout: TimeInterval = 10
    /// How long a fresh engine gets to connect (first run compiles and imports a lot).
    public static let connectTimeout: TimeInterval = 90

    private let link: EngineLink
    private let queue = DispatchQueue(label: "friday.supervisor")
    private var launch: () -> EngineLaunch?
    private var settings: () -> [String: String]
    private var process: Process?
    private var policy = RestartPolicy()
    private var startedAt = Date()
    private var lastBeat = Date()
    private var connected = false
    /// The engine sends its first heartbeat only after its (slow, on a cold start) imports.
    private var beating = false
    private var enginePid: Int32 = 0
    private var wanted = false
    private var generation = 0
    private var watchdog: DispatchSourceTimer?
    private var stderrTail: [String] = []
    public let logURL: URL?

    /// Both called on the main queue.
    public var onEvent: ((EngineEvent) -> Void)?
    public var onStatus: ((Status) -> Void)?

    public init(socketPath: String, logURL: URL? = nil,
                launch: @escaping () -> EngineLaunch?, settings: @escaping () -> [String: String]) {
        link = EngineLink(path: socketPath)
        self.launch = launch
        self.settings = settings
        self.logURL = logURL
        link.onEvent = { [weak self] event in self?.queue.async { self?.handle(event) } }
        link.onConnect = { [weak self] pid in
            self?.queue.async {
                self?.connected = true; self?.enginePid = pid; self?.lastBeat = Date()
                self?.report(.running)
            }
        }
        link.onDisconnect = { [weak self] in self?.queue.async { self?.connected = false } }
    }

    public func start() {
        queue.async { [self] in
            guard !wanted else { return }
            wanted = true
            policy.reset()
            do { try link.start() } catch {
                report(.failed("Couldn’t open the engine socket: \(error)"))
                return
            }
            spawn()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            watchdog = timer
        }
    }

    /// Stop the engine and don't restart it. Blocks briefly while it exits.
    public func stop() {
        queue.sync {
            wanted = false
            generation += 1
            watchdog?.cancel(); watchdog = nil
            link.send(.shutdown)
        }
        let running = queue.sync { process }
        if let running, running.isRunning {
            let deadline = Date().addingTimeInterval(3)
            while running.isRunning && Date() < deadline { usleep(50_000) }
            if running.isRunning { running.terminate() }
        }
        link.stop()
        queue.sync { killEngine(); process = nil; report(.stopped) }
    }

    /// Restart with fresh settings (after a settings change, or "Restart" in Advanced).
    public func restart() {
        queue.async { [self] in
            guard wanted else { return }
            policy.reset()
            generation += 1
            terminate()
            spawn()
        }
    }

    public func send(_ command: HostCommand) { link.send(command) }

    // MARK: - Test hooks

    var enginePidForTesting: Int32 { queue.sync { process?.processIdentifier ?? 0 } }
    func killEngineForTesting() { queue.sync { if let process { kill(process.processIdentifier, SIGKILL) } } }

    // MARK: - On the supervisor queue

    private func spawn() {
        guard wanted else { return }
        guard let plan = launch() else {
            report(.failed("Friday’s engine folder wasn’t found. Set it in Settings, Advanced."))
            return
        }
        let token = (0..<32).map { _ in String(UInt8.random(in: 0...15), radix: 16) }.joined()
        link.expect(token: token, settings: settings())

        let child = Process()
        child.executableURL = URL(fileURLWithPath: plan.executable)
        child.arguments = plan.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: plan.directory)
        var environment = plan.environment
        environment["FRIDAY_SOCKET"] = link.path
        environment["FRIDAY_TOKEN"] = token
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        child.standardError = errors
        let log = openLog()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            log?.write(data)
            if let text = String(data: data, encoding: .utf8) {
                self?.queue.async {
                    self?.stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
                    self?.stderrTail = Array(self?.stderrTail.suffix(8) ?? [])
                }
            }
        }
        let mine = generation
        child.terminationHandler = { [weak self] finished in
            self?.queue.async { self?.exited(finished, generation: mine) }
        }
        connected = false
        beating = false
        enginePid = 0
        startedAt = Date()
        lastBeat = Date()
        stderrTail = []
        report(.starting)
        do {
            try child.run()
            process = child
        } catch {
            report(.failed("Couldn’t start the engine: \(error.localizedDescription)"))
        }
    }

    private func exited(_ finished: Process, generation mine: Int) {
        guard mine == generation, wanted else { return }  // we stopped it on purpose
        process = nil
        connected = false
        switch policy.crashed(at: Date(), startedAt: startedAt) {
        case .restart(let delay):
            report(.restarting(in: delay))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wanted, mine == self.generation, self.process == nil else { return }
                self.spawn()
            }
        case .giveUp:
            let why = stderrTail.last.map { ": \($0.suffix(160))" } ?? ""
            report(.failed("The engine keeps stopping\(why)"))
        }
    }

    private func check() {
        guard wanted, let process, process.isRunning else { return }
        let now = Date()
        // Until the first heartbeat the engine is still starting and gets the long
        // allowance; the short deadline only applies once it has begun to beat.
        let stuck = beating
            ? now.timeIntervalSince(lastBeat) > Self.heartbeatTimeout
            : now.timeIntervalSince(startedAt) > Self.connectTimeout
        if stuck { terminate() }  // its termination handler schedules the restart
    }

    private func terminate() {
        killEngine()
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
    }

    /// The engine is a child of the launcher (uv), so it is stopped by its own
    /// pid, which it reported when it connected.
    private func killEngine() {
        if enginePid > 0 { kill(enginePid, SIGKILL) }
        enginePid = 0
    }

    private func handle(_ event: EngineEvent) {
        lastBeat = Date()
        if case .heartbeat = event { beating = true; return }
        if case .hello = event { return }
        DispatchQueue.main.async { [onEvent] in onEvent?(event) }
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { [onStatus] in onStatus?(status) }
    }

    private func openLog() -> FileHandle? {
        guard let logURL else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Start a new file past 5 MB, keeping one old one.
        if let size = try? manager.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 5_000_000 {
            let old = logURL.deletingPathExtension().appendingPathExtension("1.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: logURL, to: old)
        }
        if !manager.fileExists(atPath: logURL.path) { manager.createFile(atPath: logURL.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
