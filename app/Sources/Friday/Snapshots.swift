import AppKit
import FridayCore
import FridayUI
import SwiftUI

/// Draws each surface off screen, in light and dark, for the design review.
@MainActor
enum Snapshots {
    static func run(into folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        FridayFont.register()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let scheme: ColorScheme = name == "dark" ? .dark : .light
            func shot<V: View>(_ file: String, _ view: V) {
                save(view.environment(\.solidGlass, true).environment(\.colorScheme, scheme),
                     appearance: appearance, to: folder.appendingPathComponent("\(file)-\(name).png"))
            }

            shot("popover", backdrop(scheme) { popover(.listening, conversation: false) })
            shot("popover-warning", backdrop(scheme) { popover(.speaking, conversation: true, warning: .ttsQuota) })
            shot("popover-paused", backdrop(scheme) { popover(.paused, conversation: false, empty: true) })
            shot("popover-takeover", backdrop(scheme) { popover(.paused, conversation: false, empty: true, other: true) })
            shot("hud-and-glyphs", backdrop(scheme) { states })
            for step in SetupView.Step.allCases {
                shot("setup-\(step.rawValue + 1)-\(step)",
                     SetupView(engine: engine(.hearing, level: 0.55), store: store, step: step, results: [
                         .claude: .ok("Claude Code found at ~/.local/bin/claude"),
                         .microphone: .ok("Friday can use the microphone"),
                         .model: .ok("The speech model is already on this Mac"),
                     ], wakeCount: 2))
            }
            for pane in SettingsView.Pane.allCases {
                shot("settings-\(pane.rawValue.lowercased().replacingOccurrences(of: " & ", with: "-"))", SettingsView(store: store, engine: engine(.listening), pane: pane))
            }
        }
        print("Wrote snapshots to \(folder.path)")
        exit(0)
    }

    /// Settings that live in a scratch file and a keychain entry that doesn't exist.
    private static let store = SettingsStore(
        url: FileManager.default.temporaryDirectory.appendingPathComponent("friday-snapshots/settings.json"),
        keychain: KeychainItem(service: "com.ronnie434.Friday.snapshots", account: "none"))

    private static func engine(_ state: FridayState, conversation: Bool = true, level: Double = 0.6,
                               warning: FridayWarning? = nil, empty: Bool = false) -> EngineModel {
        let model = FakeEngine(autoplay: false)
        model.state = state
        model.conversation = conversation
        model.micLevel = level
        model.outLevel = level
        model.warning = warning
        model.inputs = ["CMTECK", "MacBook Pro Microphone"]
        model.outputs = ["MacBook Pro Speakers"]
        if empty { model.heard = ""; model.reply = "" }
        return model
    }

    private static func popover(_ state: FridayState, conversation: Bool, warning: FridayWarning? = nil,
                                empty: Bool = false, other: Bool = false) -> some View {
        let model = engine(state, conversation: conversation, warning: warning, empty: empty)
        model.otherFridayRunning = other
        return PopoverView(engine: model)
            .glass(RoundedRectangle(cornerRadius: Radius.panel))
    }

    /// Every HUD state and every menu bar glyph on one sheet.
    private static var states: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ForEach([FridayState.hearing, .thinking, .speaking], id: \.self) { state in
                HStack(spacing: Space.l) {
                    Text(state.rawValue.uppercased()).monoLabel(10, medium: true).foregroundStyle(Color.muted)
                        .frame(width: 80, alignment: .leading)
                    HUDView(engine: engine(state))
                    if state == .hearing {
                        HUDView(engine: engine(state), pinnedCaption: "what’s on my calendar today?")
                    }
                }
            }
            HStack(spacing: Space.l) {
                Text("MENU BAR").monoLabel(10, medium: true).foregroundStyle(Color.muted)
                    .frame(width: 80, alignment: .leading)
                ForEach([FridayState.listening, .hearing, .thinking, .speaking, .paused], id: \.self) { state in
                    VStack(spacing: 4) {
                        MenuBarGlyph(state: state).foregroundStyle(Color.ink)
                        Text(state.rawValue).monoLabel(8).foregroundStyle(Color.muted)
                    }
                }
                VStack(spacing: 4) {
                    MenuBarGlyph(state: .listening, warning: .ttsQuota)
                    Text("warning").monoLabel(8).foregroundStyle(Color.muted)
                }
                VStack(spacing: 4) {
                    MenuBarGlyph(state: .error, warning: .micDenied)
                    Text("error").monoLabel(8).foregroundStyle(Color.muted)
                }
            }
        }
    }

    /// Something desktop-like behind the floating surfaces.
    private static func backdrop<V: View>(_ scheme: ColorScheme, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(36)
            .background(LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.10, green: 0.12, blue: 0.18), Color(red: 0.05, green: 0.06, blue: 0.09)]
                    : [Color(red: 0.86, green: 0.90, blue: 0.96), Color(red: 0.95, green: 0.94, blue: 0.92)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private static func save<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))  // let SwiftUI settle
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
