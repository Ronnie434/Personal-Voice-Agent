import AppKit
import AVFoundation
import FridayCore
import FridayUI
import SwiftUI

/// The checkout this app was built from: where the engine runs from unless
/// Settings names another folder.
let builtFrom: String = {
    if let override = ProcessInfo.processInfo.environment["FRIDAY_ENGINE_DIR"] { return override }
    if let baked = Bundle.main.object(forInfoDictionaryKey: "FridayEngineDirectory") as? String { return baked }
    // app/Sources/Friday/FridayApp.swift -> the repository root
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path
}()

/// Lets exactly one of several racing tasks go ahead.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `Friday --fake` runs the scripted engine, for working on the design.
    static let fake = CommandLine.arguments.contains("--fake")
    static let store = SettingsStore()
    static let engine: EngineModel = fake ? FakeEngine() : LiveEngine(store: store, defaultDirectory: builtFrom)
    static var openSetup: () -> Void = {}
    static var reportPower: () -> Void = {}

    private var hud: HUDController?
    private var pauseKey: Hotkey?
    private var hudSetting: Task<Void, Never>?
    private let system = SystemEvents()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FridayFont.register()
        NSApp.setActivationPolicy(.accessory)
        hud = HUDController(engine: Self.engine, isEnabled: { Self.store.settings.showHUD })
        pauseKey = Hotkey.pause { Self.engine.togglePause() }
        hudSetting = Task { [weak self] in
            for await show in Self.store.$settings.map(\.showHUD).removeDuplicates().values {
                _ = show
                self?.hud?.refresh()
            }
        }

        guard let live = Self.engine as? LiveEngine else { return }
        // Audio streams rarely survive sleep or a device switch: start a fresh
        // engine, between conversations.
        system.onWake = { live.restartWhenIdle(reason: "wake") }
        system.onAudioDeviceChange = { live.restartWhenIdle(reason: "audio device") }
        system.onPowerChange = { onBattery in
            live.setAutoPaused(onBattery && Self.store.settings.pauseOnBattery)
        }
        system.start()
        Self.reportPower = { [system] in system.reportPower() }
        live.microphoneAllowed = Self.microphoneAllowed
        if Self.store.settings.setupDone {
            Task { await live.start() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.openSetup() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        (Self.engine as? LiveEngine)?.stop()
    }

    /// Ask for the microphone as Friday; the engine, its child, is covered by
    /// the same grant.
    static func microphoneAllowed() async -> Bool {
        // Only a real app bundle can ask; `swift run` has no usage description.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              ProcessInfo.processInfo.environment["FRIDAY_NO_AUDIO"] != "1" else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        // Not asked yet. Ask, but don't wait for ever: with the screen locked or
        // the prompt behind something, macOS may not answer for a long time. After
        // a while start anyway (the engine opening the mic asks as Friday too) and
        // restart the engine the moment the answer is yes, so it hears from then on.
        let answer = Task { await AVCaptureDevice.requestAccess(for: .audio) }
        // Whichever comes first: the answer, or 20 seconds. (Not a task group: it
        // would wait for the unanswered prompt before returning.)
        let first: Bool? = await withCheckedContinuation { continuation in
            let once = Once()
            Task { let granted = await answer.value; if once.claim() { continuation.resume(returning: granted) } }
            Task { try? await Task.sleep(for: .seconds(20)); if once.claim() { continuation.resume(returning: nil) } }
        }
        if let first { return first }
        Task {
            let granted = await answer.value
            guard let live = engine as? LiveEngine else { return }
            if granted {
                live.restartEngine()
            } else {
                live.stop()
                live.warning = .micDenied
                live.state = .error
            }
        }
        return true
    }

    static var checks: SetupView.Checks {
        SetupView.Checks(
            claude: {
                let path = Machine.loginPath()
                guard let claude = Machine.find("claude", in: path + ":" + NSHomeDirectory() + "/.claude/local") else {
                    return .failed("Claude Code isn’t installed", fix: "Get Claude Code")
                }
                guard Machine.find("uv", in: path) != nil else {
                    return .failed("uv isn’t installed, and the engine needs it", fix: "Get uv")
                }
                guard Machine.isEngineDirectory(builtFrom) || Machine.isEngineDirectory(store.settings.engineDirectory) else {
                    return .failed("Friday’s engine folder wasn’t found", fix: "Open Settings")
                }
                return .ok("Claude Code found at \((claude as NSString).abbreviatingWithTildeInPath)")
            },
            microphone: {
                guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
                    return .ok("Asked for when the engine starts")
                }
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .ok("Friday can use the microphone")
                case .notDetermined: return .failed("Friday hasn’t been allowed yet", fix: "Allow")
                default: return .failed("The microphone is switched off for Friday", fix: "Open Privacy settings")
                }
            },
            model: {
                Machine.speechModelPresent()
                    ? .ok("The speech model is already on this Mac")
                    : .ok("Will download when Friday first starts (1.5 GB)")
            },
            startEngine: {
                guard let live = engine as? LiveEngine, !live.started else { return }
                Task { await live.start() }
            },
            fix: { step in
                switch step {
                case .claude:
                    NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
                case .microphone:
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                default: break
                }
            })
    }
}

struct FridayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var engine = AppDelegate.engine
    @ObservedObject private var store = AppDelegate.store
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopoverView(engine: engine, openSettings: { show("settings") }, fix: fix)
                .onAppear { AppDelegate.openSetup = { show("setup") } }
            Divider()
            HStack {
                Button("Run setup again") { show("setup") }
                Spacer()
                Button("Quit Friday") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.muted)
            .padding(.horizontal, 16).padding(.vertical, 10)
        } label: {
            Image(nsImage: MenuBarGlyph.image(state: engine.state, warning: engine.problem == nil ? engine.warning : .claudeMissing))
                .onAppear { AppDelegate.openSetup = { show("setup") } }
        }
        .menuBarExtraStyle(.window)

        Window("Set up Friday", id: "setup") {
            SetupView(engine: engine, store: store, checks: AppDelegate.checks) {
                store.settings.setupDone = true
                NSApp.keyWindow?.close()
                if let live = engine as? LiveEngine, !live.started {
                    Task { await live.start() }
                }
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Friday Settings", id: "settings") {
            SettingsView(store: store, engine: engine) {
                NSWorkspace.shared.activateFileViewerSelecting([FridayPaths.engineLog])
            }
            .onChange(of: store.settings.pauseOnBattery) { _, _ in AppDelegate.reportPower() }
        }
        .windowResizability(.contentSize)
    }

    private func fix(_ warning: FridayWarning) {
        switch warning {
        case .micDenied:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .claudeMissing, .claudeAuth:
            show("setup")
        default:
            show("settings")
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
