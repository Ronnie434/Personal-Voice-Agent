import AVFoundation
import Foundation
import FridayCore

// `Friday --snapshots <folder>` draws every surface to PNG files and exits.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshots"), CommandLine.arguments.count > flag + 1 {
    MainActor.assumeIsolated { Snapshots.run(into: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
} else if let flag = CommandLine.arguments.firstIndex(of: "--status"), CommandLine.arguments.count > flag + 1 {
    // `open -W Friday.app --args --status <file>`: what this app is allowed and what it sees.
    let mic = ["notDetermined", "restricted", "denied", "authorized"][AVCaptureDevice.authorizationStatus(for: .audio).rawValue]
    let report = "microphone=\(mic)\notherFridays=\(Machine.otherFridays())\nengineDirectory=\(builtFrom) ok=\(Machine.isEngineDirectory(builtFrom))\nuv=\(Machine.find("uv", in: Machine.loginPath()) ?? "missing")\n"
    try? report.write(toFile: CommandLine.arguments[flag + 1], atomically: true, encoding: .utf8)
} else {
    FridayApp.main()
}
