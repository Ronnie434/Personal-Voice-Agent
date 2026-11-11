import Foundation
import Security

/// settings.json, version 1. Everything except the ElevenLabs key, which lives
/// in the Keychain.
public struct FridaySettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = FridaySettings.currentVersion
    public var setupDone = false
    public var showHUD = true
    public var openChime = true
    public var closeChime = false
    /// "elevenlabs" (needs a key), or go straight to the backup voice.
    public var voice = "elevenlabs"
    /// "kokoro" or "system".
    public var backupVoice = "kokoro"
    public var wakeWord = "friday"
    public var conversationSecs = 60.0
    public var bargeIn = true
    /// Device names; empty means the system default.
    public var inputDevice = ""
    public var outputDevice = ""
    public var claudeModel = "sonnet"
    public var userName = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    public var permissionMode = "auto"
    /// The checkout that holds the engine (the folder with agent.py). Empty: the
    /// one this app was built from.
    public var engineDirectory = ""
    /// Stop listening while the Mac runs on battery.
    public var pauseOnBattery = false

    public init() {}

    /// Unknown or missing keys keep their defaults, so old files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = FridaySettings()
        setupDone = get(.setupDone, d.setupDone)
        showHUD = get(.showHUD, d.showHUD)
        openChime = get(.openChime, d.openChime)
        closeChime = get(.closeChime, d.closeChime)
        voice = get(.voice, d.voice)
        backupVoice = get(.backupVoice, d.backupVoice)
        wakeWord = get(.wakeWord, d.wakeWord)
        conversationSecs = get(.conversationSecs, d.conversationSecs)
        bargeIn = get(.bargeIn, d.bargeIn)
        inputDevice = get(.inputDevice, d.inputDevice)
        outputDevice = get(.outputDevice, d.outputDevice)
        claudeModel = get(.claudeModel, d.claudeModel)
        userName = get(.userName, d.userName)
        permissionMode = get(.permissionMode, d.permissionMode)
        engineDirectory = get(.engineDirectory, d.engineDirectory)
        pauseOnBattery = get(.pauseOnBattery, d.pauseOnBattery)
        version = FridaySettings.currentVersion  // migrations for later versions go here
    }

    /// The `configure` payload: the engine's own setting names. Only values the
    /// user can change in the app are sent; the rest stay at the engine's defaults.
    public func engineSettings(elevenLabsKey: String?) -> [String: String] {
        var out: [String: String] = [
            "WAKE_WORD": wakeWord.trimmingCharacters(in: .whitespaces).lowercased().isEmpty
                ? "friday" : wakeWord.trimmingCharacters(in: .whitespaces).lowercased(),
            "CONVERSATION_SECS": String(Int(conversationSecs)),
            "INSTANT_BARGE_IN": bargeIn ? "1" : "0",
            "CLAUDE_MODEL": claudeModel,
            "USER_NAME": userName,
            "PERMISSION_MODE": permissionMode,
            "BACKUP_VOICE": backupVoice,
            "INPUT_DEVICE": inputDevice,
            "OUTPUT_DEVICE": outputDevice,
        ]
        if voice != "elevenlabs" {
            out["ELEVENLABS_API_KEY"] = ""  // overrides a key in the checkout's .env
        } else if let elevenLabsKey, !elevenLabsKey.isEmpty {
            out["ELEVENLABS_API_KEY"] = elevenLabsKey
        }
        return out
    }

    /// Settings whose change needs a new engine (all of the engine's, today).
    public func needsRestart(comparedTo old: FridaySettings, keyChanged: Bool = false) -> Bool {
        keyChanged || engineSettings(elevenLabsKey: nil) != old.engineSettings(elevenLabsKey: nil)
            || engineDirectory != old.engineDirectory
    }
}

public enum SettingsFile {
    public static func load(from url: URL) -> FridaySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(FridaySettings.self, from: data) else {
            return FridaySettings()
        }
        return settings
    }

    public static func save(_ settings: FridaySettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// One secret in the login keychain.
public struct KeychainItem: Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store `value`; an empty value deletes the item.
    @discardableResult
    public func write(_ value: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Where Friday keeps things.
public enum FridayPaths {
    /// FRIDAY_SUPPORT_DIR moves everything (settings, socket, log) for a trial run.
    private static let override = ProcessInfo.processInfo.environment["FRIDAY_SUPPORT_DIR"]

    public static var support: URL {
        if let override { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Friday")
    }
    public static var settings: URL { support.appendingPathComponent("settings.json") }
    public static var socket: String { support.appendingPathComponent("run/friday.sock").path }
    public static var engineLog: URL {
        if let override { return URL(fileURLWithPath: override).appendingPathComponent("engine.log") }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Friday/engine.log")
    }
}

/// Finding the things the engine needs on this Mac.
public enum Machine {
    /// PATH as the user's login shell sees it. An app started from Finder gets a
    /// bare PATH, and Claude needs the real one to find gh, git, node and the rest.
    public static func loginPath() -> String {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
            + NSHomeDirectory() + "/.local/bin"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lic", "echo __PATH__$PATH"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        do { try shell.run() } catch { return fallback }
        let deadline = Date().addingTimeInterval(5)
        while shell.isRunning && Date() < deadline { usleep(20_000) }
        if shell.isRunning { shell.terminate(); return fallback }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__PATH__") }) else {
            return fallback
        }
        let path = String(line.dropFirst("__PATH__".count))
        return path.isEmpty ? fallback : path
    }

    public static func find(_ tool: String, in path: String) -> String? {
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// True if `folder` looks like a Friday checkout.
    public static func isEngineDirectory(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: folder + "/agent.py")
            && FileManager.default.fileExists(atPath: folder + "/engine/friday_engine/__main__.py")
    }

    /// Start the engine from a checkout, through uv, with the user's PATH.
    public static func engineLaunch(directory: String, path: String,
                                    extra: [String: String] = [:]) -> EngineLaunch? {
        guard isEngineDirectory(directory), let uv = find("uv", in: path) else { return nil }
        var environment = ["PATH": path, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                           "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory()]
        environment.merge(extra) { _, new in new }
        return EngineLaunch(executable: uv, arguments: ["run", "--quiet", "agent.py"],
                            directory: directory, environment: environment)
    }

    /// Fridays started some other way (from a terminal, with `uv run agent.py`):
    /// their process ids. Two at once would both answer, so the app won't start
    /// its own while one is running. `excluding` is this app's own process.
    public static func otherFridays(excluding app: Int32 = ProcessInfo.processInfo.processIdentifier) -> [Int32] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        return otherFridays(inProcessList: text, excluding: app)
    }

    static func otherFridays(inProcessList text: String, excluding app: Int32) -> [Int32] {
        var parent: [Int32: Int32] = [:]
        var engines: [Int32] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            parent[pid] = ppid
            let command = parts[2]
            // The engine itself or the `uv run` that launched it, not an editor or a grep.
            let isEngine = (command.contains("agent.py") && (command.contains("python") || command.hasPrefix("uv ") || command.contains("/uv run")))
                || command.contains("-m friday_engine")
            if isEngine && !command.contains("--text") && !command.contains("--devices") { engines.append(pid) }
        }
        func descendsFromApp(_ pid: Int32) -> Bool {
            var current = pid, hops = 0
            while let up = parent[current], hops < 32 {
                if up == app { return true }
                current = up; hops += 1
            }
            return false
        }
        return engines.filter { $0 != app && !descendsFromApp($0) }
    }

    /// The speech model has been downloaded (it is 1.5 GB, fetched on first use).
    public static func speechModelPresent(_ repo: String = "mlx-community/whisper-large-v3-turbo") -> Bool {
        let folder = NSHomeDirectory() + "/.cache/huggingface/hub/models--"
            + repo.replacingOccurrences(of: "/", with: "--") + "/snapshots"
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).isEmpty == false
    }
}
