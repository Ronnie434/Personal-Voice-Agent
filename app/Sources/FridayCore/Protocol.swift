import Foundation

// App ↔ engine protocol v1 (docs/protocol.md): JSON lines over a Unix socket.

public let protocolVersion = 1

/// What the engine tells the app.
public enum EngineEvent: Equatable, Sendable {
    case hello(token: String, pid: Int32, engine: String)
    case state(String, conversation: Bool)
    case levels(mic: Double, out: Double)
    case heard(String)
    case reply(String, final: Bool)
    case warning(String)
    case devices(inputs: [String], outputs: [String], defaultInput: String?, defaultOutput: String?)
    case heartbeat
    /// A type this build doesn't know. Ignored, so a newer engine still works.
    case unknown(String)

    public static func decode(_ line: Data) -> EngineEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        func names(_ key: String) -> [String] {
            (object[key] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        switch type {
        case "hello":
            return .hello(token: object["token"] as? String ?? "",
                          pid: Int32(object["pid"] as? Int ?? 0), engine: object["engine"] as? String ?? "")
        case "state":
            guard let state = object["state"] as? String else { return nil }
            return .state(state, conversation: object["conversation"] as? Bool ?? false)
        case "levels":
            return .levels(mic: object["mic"] as? Double ?? 0, out: object["out"] as? Double ?? 0)
        case "heard":
            return .heard(object["text"] as? String ?? "")
        case "reply":
            return .reply(object["text"] as? String ?? "", final: object["final"] as? Bool ?? false)
        case "warning":
            return .warning(object["code"] as? String ?? "")
        case "devices":
            return .devices(inputs: names("inputs"), outputs: names("outputs"),
                            defaultInput: object["default_input"] as? String,
                            defaultOutput: object["default_output"] as? String)
        case "heartbeat":
            return .heartbeat
        default:
            return .unknown(type)
        }
    }
}

/// What the app tells the engine.
public enum HostCommand: Equatable, Sendable {
    case configure([String: String])
    case pause, resume, interrupt, shutdown
    case ask(String)

    public func encode() -> Data {
        var object: [String: Any] = ["v": protocolVersion]
        switch self {
        case .configure(let settings): object["type"] = "configure"; object["settings"] = settings
        case .pause: object["type"] = "pause"
        case .resume: object["type"] = "resume"
        case .interrupt: object["type"] = "interrupt"
        case .shutdown: object["type"] = "shutdown"
        case .ask(let text): object["type"] = "ask"; object["text"] = text
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Splits a byte stream into lines, whatever sizes the chunks arrive in.
public struct LineBuffer {
    private var pending = Data()
    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
