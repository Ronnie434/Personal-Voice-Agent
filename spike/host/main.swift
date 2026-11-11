// M0 spike host: a menu-bar-style (LSUIElement) app that runs the embedded
// Python engine as a child process and records what happened.
import AppKit

let launch = Date()
let args = Array(CommandLine.arguments.dropFirst())
let mode = args.contains("--mic") ? "mic" : "transcribe"
let tag = args.first(where: { $0.hasPrefix("--tag=") })?.dropFirst(6) ?? "run"

let res = Bundle.main.resourceURL!
let python = res.appendingPathComponent("python/bin/python3.12")
let script = res.appendingPathComponent("engine/spike_engine.py")
let home = FileManager.default.homeDirectoryForCurrentUser
let outDir = home.appendingPathComponent("Library/Logs/FridaySpike")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let child = Process()
child.executableURL = python
var childArgs = ["-I", "-B", script.path, mode]
if mode == "transcribe" {
    childArgs += [res.appendingPathComponent("engine/hello.wav").path,
                  "mlx-community/whisper-large-v3-turbo"]
    if args.contains("--words") { childArgs.append("--words") }
}
child.arguments = childArgs
var env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1",
           "PYTHONDONTWRITEBYTECODE": "1",
           "NUMBA_CACHE_DIR": outDir.appendingPathComponent("numba").path]
child.environment = env
let stdout = Pipe(), stderr = Pipe()
child.standardOutput = stdout
child.standardError = stderr

child.terminationHandler = { p in
    let o = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let engine = o.split(separator: "\n").last.map(String.init) ?? "null"
    let report = """
    {"tag":"\(tag)","mode":"\(mode)","exit":\(p.terminationStatus),"reason":\(p.terminationReason.rawValue),\
    "host_total_s":\(String(format: "%.3f", Date().timeIntervalSince(launch))),"engine":\(engine.isEmpty ? "null" : engine)}
    """
    try? report.write(to: outDir.appendingPathComponent("\(tag)-\(mode).json"), atomically: true, encoding: .utf8)
    try? e.write(to: outDir.appendingPathComponent("\(tag)-\(mode).stderr.txt"), atomically: true, encoding: .utf8)
    exit(0)
}
do { try child.run() } catch {
    try? "{\"tag\":\"\(tag)\",\"spawn_error\":\"\(error)\"}".write(
        to: outDir.appendingPathComponent("\(tag)-\(mode).json"), atomically: true, encoding: .utf8)
    exit(1)
}
app.run()
