import AppKit
import SwiftUI

/// The pill under the menu bar while a conversation is open: the orb, and for
/// two seconds the words Friday just heard.
public struct HUDView: View {
    @ObservedObject var engine: EngineModel
    @State private var caption = ""
    var pinnedCaption: String?

    public init(engine: EngineModel, pinnedCaption: String? = nil) {
        self.engine = engine
        self.pinnedCaption = pinnedCaption
    }

    public var body: some View {
        let words = pinnedCaption ?? caption
        HStack(spacing: Space.s) {
            Orb(state: engine.state, level: engine.state == .speaking ? engine.outLevel : engine.micLevel,
                size: 18)
                .padding(.leading, 5)
            if !words.isEmpty {
                Text(words).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).truncationMode(.tail)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            } else if engine.state == .thinking || engine.state == .speaking {
                Text(engine.state == .thinking ? "THINKING" : "SPEAKING")
                    .font(FridayFont.mono(10, medium: true)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
                    .transition(.opacity)
            }
        }
        .padding(.leading, Space.s).padding(.trailing, words.isEmpty && engine.state == .hearing ? Space.s : 14)
        .frame(height: 36)
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize()
        .glass(Capsule(), dark: true)
        .animation(Motion.spring, value: words)
        .animation(Motion.spring, value: engine.state)
        .onChange(of: engine.heard) { _, heard in
            caption = heard
            Task {
                try? await Task.sleep(for: .seconds(2))
                if caption == heard { caption = "" }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Friday is \(engine.state.label.lowercased())")
    }
}

/// A borderless panel that floats under the menu bar, ignores clicks and never
/// takes focus. Shown only while a conversation is open.
@MainActor
public final class HUDController {
    private let panel: NSPanel
    private var watcher: Task<Void, Never>?
    private var announcer: Task<Void, Never>?

    public init(engine: EngineModel, isEnabled: @escaping () -> Bool = { true }) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(engine: engine).frame(width: 420, height: 60))
        panel.contentView = host

        watcher = Task { [weak self] in
            for await open in engine.$conversation.values {
                self?.set(visible: open && isEnabled())
            }
        }
        announcer = Task {
            // VoiceOver users hear what the bars show.
            for await state in engine.$state.removeDuplicates().values
            where [.hearing, .thinking, .paused, .error].contains(state) {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                    .announcement: "Friday: \(state.label)",
                    .priority: NSAccessibilityPriorityLevel.low.rawValue,
                ])
            }
        }
    }

    private func set(visible: Bool) {
        guard let screen = NSScreen.main else { return }
        if visible {
            // Centred, just below the menu bar (and below the notch where there is one).
            let top = screen.visibleFrame.maxY
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                         y: top - panel.frame.height - 2))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        } else if panel.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [panel] in panel.orderOut(nil) })
        }
    }
}
