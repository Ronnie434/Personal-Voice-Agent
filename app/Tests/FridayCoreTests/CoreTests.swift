import XCTest
@testable import FridayCore

final class ProtocolTests: XCTestCase {
    private func decode(_ json: String) -> EngineEvent? { EngineEvent.decode(Data(json.utf8)) }

    func testDecodesEveryEngineEvent() {
        XCTAssertEqual(decode(#"{"v":1,"type":"hello","token":"abc","pid":42,"engine":"0.2.0"}"#),
                       .hello(token: "abc", pid: 42, engine: "0.2.0"))
        XCTAssertEqual(decode(#"{"v":1,"type":"state","state":"thinking","conversation":true}"#),
                       .state("thinking", conversation: true))
        XCTAssertEqual(decode(#"{"v":1,"type":"levels","mic":0.5,"out":0}"#), .levels(mic: 0.5, out: 0))
        XCTAssertEqual(decode(#"{"v":1,"type":"heard","text":"what time is it"}"#), .heard("what time is it"))
        XCTAssertEqual(decode(#"{"v":1,"type":"reply","text":"Noon.","final":true}"#), .reply("Noon.", final: true))
        XCTAssertEqual(decode(#"{"v":1,"type":"warning","code":"tts_quota"}"#), .warning("tts_quota"))
        XCTAssertEqual(decode(#"{"v":1,"type":"heartbeat","t":1.5}"#), .heartbeat)
        XCTAssertEqual(
            decode(#"{"v":1,"type":"devices","inputs":[{"index":2,"name":"CMTECK"}],"outputs":[],"default_input":"CMTECK","default_output":null}"#),
            .devices(inputs: ["CMTECK"], outputs: [], defaultInput: "CMTECK", defaultOutput: nil))
    }

    func testUnknownAndBrokenMessages() {
        XCTAssertEqual(decode(#"{"v":1,"type":"tool_activity","name":"Bash"}"#), .unknown("tool_activity"))
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode(#"{"v":1}"#))
    }

    func testEncodesCommandsAsOneLine() throws {
        for command in [HostCommand.pause, .resume, .interrupt, .shutdown, .ask("hi \"there\"\nnew line"),
                        .configure(["WAKE_WORD": "friday"])] {
            let data = command.encode()
            XCTAssertEqual(data.last, 0x0A)
            XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1, "exactly one newline, at the end")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["v"] as? Int, 1)
        }
        let ask = try XCTUnwrap(JSONSerialization.jsonObject(with: HostCommand.ask("hello").encode()) as? [String: Any])
        XCTAssertEqual(ask["type"] as? String, "ask")
        XCTAssertEqual(ask["text"] as? String, "hello")
    }

    func testLineBufferHandlesSplitAndJoinedChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n{\"b\":2}\n\n{\"c\"".utf8)).map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(buffer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
    }
}

final class RestartPolicyTests: XCTestCase {
    func testBacksOffThenGivesUpAfterFiveCrashesInTenMinutes() {
        var policy = RestartPolicy()
        var now = Date(timeIntervalSince1970: 1_000)
        var decisions: [RestartPolicy.Decision] = []
        for _ in 0..<5 {
            decisions.append(policy.crashed(at: now, startedAt: now.addingTimeInterval(-3)))
            now.addTimeInterval(20)
        }
        XCTAssertEqual(decisions, [.restart(after: 1), .restart(after: 2), .restart(after: 4),
                                   .restart(after: 8), .giveUp])
    }

    func testOldCrashesAreForgotten() {
        var policy = RestartPolicy()
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<4 { _ = policy.crashed(at: now, startedAt: now.addingTimeInterval(-3)); now.addTimeInterval(1) }
        now.addTimeInterval(RestartPolicy.window + 1)
        // Only this crash is inside the window, and the last run was a long, healthy one.
        XCTAssertEqual(policy.crashed(at: now, startedAt: now.addingTimeInterval(-700)), .restart(after: 1))
    }

    func testDelayCapsAtThirtySeconds() {
        var policy = RestartPolicy()
        var now = Date(timeIntervalSince1970: 1_000)
        var last = RestartPolicy.Decision.giveUp
        // Crashes spaced so that fewer than five ever fall inside ten minutes.
        for _ in 0..<8 { last = policy.crashed(at: now, startedAt: now.addingTimeInterval(-3)); now.addTimeInterval(200) }
        XCTAssertEqual(last, .restart(after: 30))
    }

    func testResetStartsOver() {
        var policy = RestartPolicy()
        let now = Date()
        for _ in 0..<5 { _ = policy.crashed(at: now, startedAt: now) }
        policy.reset()
        XCTAssertEqual(policy.crashed(at: now, startedAt: now), .restart(after: 1))
    }
}

final class SettingsTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("friday-tests-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testMissingFileGivesDefaults() {
        let settings = SettingsFile.load(from: folder.appendingPathComponent("settings.json"))
        XCTAssertEqual(settings.wakeWord, "friday")
        XCTAssertEqual(settings.version, 1)
        XCTAssertFalse(settings.setupDone)
    }

    func testRoundTrip() throws {
        let url = folder.appendingPathComponent("deep/settings.json")
        var settings = FridaySettings()
        settings.wakeWord = "jarvis"
        settings.conversationSecs = 30
        settings.setupDone = true
        try SettingsFile.save(settings, to: url)
        XCTAssertEqual(SettingsFile.load(from: url), settings)
    }

    func testOlderFileWithMissingAndUnknownKeysStillLoads() throws {
        let url = folder.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":0,"wakeWord":"computer","retiredOption":true,"bargeIn":"yes"}"#.utf8).write(to: url)
        let settings = SettingsFile.load(from: url)
        XCTAssertEqual(settings.wakeWord, "computer")
        XCTAssertEqual(settings.version, 1)
        XCTAssertTrue(settings.bargeIn, "a value of the wrong type falls back to the default")
        XCTAssertEqual(settings.claudeModel, "sonnet")
    }

    func testEngineSettings() {
        var settings = FridaySettings()
        settings.wakeWord = "  Friday "
        settings.inputDevice = "CMTECK"
        var sent = settings.engineSettings(elevenLabsKey: "secret")
        XCTAssertEqual(sent["WAKE_WORD"], "friday")
        XCTAssertEqual(sent["INPUT_DEVICE"], "CMTECK")
        XCTAssertEqual(sent["ELEVENLABS_API_KEY"], "secret")
        XCTAssertEqual(sent["INSTANT_BARGE_IN"], "1")

        // No key in the Keychain: say nothing, so a key in the checkout's .env still applies.
        XCTAssertNil(settings.engineSettings(elevenLabsKey: nil)["ELEVENLABS_API_KEY"])
        // The local voice was chosen: switch ElevenLabs off even if a key exists.
        settings.voice = "kokoro"
        sent = settings.engineSettings(elevenLabsKey: "secret")
        XCTAssertEqual(sent["ELEVENLABS_API_KEY"], "")
    }

    func testOnlyEngineSettingsNeedARestart() {
        let old = FridaySettings()
        var new = old
        new.showHUD = false
        new.openChime = false
        XCTAssertFalse(new.needsRestart(comparedTo: old))
        new.conversationSecs = 20
        XCTAssertTrue(new.needsRestart(comparedTo: old))
        XCTAssertTrue(old.needsRestart(comparedTo: old, keyChanged: true))
    }

    func testFindsFridaysStartedFromATerminalButNotItsOwn() {
        let list = """
          100     1 /Applications/Friday.app/Contents/MacOS/Friday
          200   100 /Users/me/.local/bin/uv run --quiet agent.py
          201   200 /Users/me/Friday/.venv/bin/python3 agent.py
          300     1 /bin/zsh -c source snapshot && uv run agent.py --debug >> logs/agent.log
          301   300 uv run agent.py --debug
          302   301 /Users/me/Documents/Personal Voice Agent/.venv/bin/python3 agent.py --debug
          400     1 /usr/bin/vim agent.py
          401     1 grep agent.py
          402     1 /Users/me/x/.venv/bin/python3 agent.py --text hello
          403     1 /opt/python -m friday_engine
        """
        XCTAssertEqual(Machine.otherFridays(inProcessList: list, excluding: 100), [301, 302, 403])
        // Seen from outside the app, the app's own engine counts too.
        XCTAssertEqual(Machine.otherFridays(inProcessList: list, excluding: 999), [200, 201, 301, 302, 403])
    }

    func testFindsToolsOnAPath() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tool = folder.appendingPathComponent("uv")
        FileManager.default.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(Machine.find("uv", in: "/nonexistent:\(folder.path)"), tool.path)
        XCTAssertNil(Machine.find("uv", in: "/nonexistent"))
        XCTAssertFalse(Machine.isEngineDirectory(folder.path))
        XCTAssertNil(Machine.engineLaunch(directory: folder.path, path: folder.path))
    }
}
