import XCTest
@testable import FridayCore

/// The supervisor against the real Python engine, with no microphone or speaker
/// (FRIDAY_NO_AUDIO) and a fake Claude. Skipped when the checkout has no .venv.
final class EngineTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path
    private var supervisor: Supervisor!
    private var events: [EngineEvent] = []
    private var statuses: [Supervisor.Status] = []
    private var socketPath = ""  // path of the engine socket for this test
    private var claudeLog = ""

    override func setUpWithError() throws {
        let python = Self.repo + "/.venv/bin/python"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "run `uv sync` first")
        let scratch = "/tmp/fri-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        socketPath = scratch + "/run/friday.sock"
        claudeLog = scratch + "/claude.json"
        let environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONPATH": Self.repo + "/engine",
            "FRIDAY_NO_AUDIO": "1", "FRIDAY_ENV_FILE": "/nonexistent/.env",
            "CLAUDE_BIN": Self.repo + "/engine/tests/fake_claude.py", "FAKE_CLAUDE_LOG": claudeLog,
            "AGENT_WORKDIR": scratch,
        ]
        supervisor = Supervisor(
            socketPath: socketPath, logURL: URL(fileURLWithPath: scratch + "/engine.log"),
            launch: { EngineLaunch(executable: python, arguments: ["-m", "friday_engine"],
                                   directory: Self.repo, environment: environment) },
            settings: { ["ELEVENLABS_API_KEY": "from-the-keychain", "USER_NAME": "Tester"] })
        supervisor.onEvent = { [weak self] in self?.events.append($0) }
        supervisor.onStatus = { [weak self] in self?.statuses.append($0) }
        supervisor.start()
    }

    override func tearDown() {
        supervisor?.stop()
    }

    /// Spin the main run loop until `condition` holds.
    private func wait(_ what: String, timeout: TimeInterval = 30, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what); events: \(events.suffix(6))")
    }

    private func state(_ name: String) -> Bool {
        events.contains { if case .state(name, _) = $0 { return true } else { return false } }
    }

    func testAskGetsAnInterimSentenceAndAFinalReply() throws {
        wait("listening") { state("listening") }
        XCTAssertEqual(statuses.first, .starting)
        XCTAssertTrue(statuses.contains(.running))

        supervisor.send(.ask("tool please"))
        wait("the reply") { events.contains(.reply("All good, see the page.", final: true)) }
        XCTAssertTrue(events.contains(.heard("tool please")))
        XCTAssertTrue(events.contains(.reply("Let me check that.", final: false)))
        XCTAssertTrue(state("thinking"))

        // The key the app sent stays with Friday: Claude's environment doesn't have it.
        let started = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: claudeLog))) as? [String: Any])
        let names = try XCTUnwrap(started["env"] as? [String])
        XCTAssertFalse(names.contains("ELEVENLABS_API_KEY"))
        XCTAssertFalse(names.contains("FRIDAY_TOKEN"))
    }

    func testPauseAndResume() {
        wait("listening") { state("listening") }
        supervisor.send(.pause)
        wait("paused") { state("paused") }
        supervisor.send(.ask("ignored"))
        supervisor.send(.resume)
        supervisor.send(.ask("hello"))
        wait("the reply") { events.contains { if case .reply(let text, true) = $0 { return text.hasPrefix("You said: hello") } else { return false } } }
        XCTAssertFalse(events.contains(.heard("ignored")))
    }

    func testEngineIsRestartedWhenItDies() {
        wait("listening") { state("listening") }
        events.removeAll()
        supervisor.killEngineForTesting()
        wait("a restart to be scheduled") {
            statuses.contains { if case .restarting = $0 { return true } else { return false } }
        }
        wait("the engine to come back") { state("listening") }
        supervisor.send(.ask("hello"))
        wait("a reply from the new engine") {
            events.contains { if case .reply(_, true) = $0 { return true } else { return false } }
        }
    }

    /// Anyone running as this user can open the socket. Without the token they
    /// must not be able to knock the real engine off it.
    func testAStrangerOnTheSocketCannotDisconnectTheEngine() throws {
        wait("listening") { state("listening") }
        let pid = supervisor.enginePidForTesting
        for payload in ["", "garbage\n", #"{"v":1,"type":"hello","token":"wrong","pid":1,"engine":"x"}"# + "\n"] {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(self.socketPath.utf8)) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(connected, 0)
            if !payload.isEmpty { _ = payload.withCString { write(fd, $0, strlen($0)) } }
            usleep(150_000)
            close(fd)
        }
        events.removeAll()
        supervisor.send(.ask("hello"))
        wait("a reply from the same engine") {
            events.contains { if case .reply(_, true) = $0 { return true } else { return false } }
        }
        XCTAssertEqual(supervisor.enginePidForTesting, pid)
        XCTAssertFalse(statuses.contains { if case .restarting = $0 { return true } else { return false } })
    }

    func testStopLeavesNoEngineBehind() {
        wait("listening") { state("listening") }
        let pid = supervisor.enginePidForTesting
        XCTAssertGreaterThan(pid, 0)
        supervisor.stop()
        usleep(300_000)
        XCTAssertEqual(kill(pid, 0), -1, "the engine process is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
