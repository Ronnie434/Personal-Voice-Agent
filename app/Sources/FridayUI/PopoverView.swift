import SwiftUI

/// Shown while a Friday started from a terminal is still running.
public struct TakeoverRow: View {
    @ObservedObject var engine: EngineModel
    public init(engine: EngineModel) { self.engine = engine }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Friday is already running from a terminal. Only one can listen at a time.")
                .font(.system(size: 12)).foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop that one and start here") { engine.takeOver() }
                .buttonStyle(PillButtonStyle(.secondary, height: 28))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The panel under the menu bar icon: status, the last exchange, type-to-ask,
/// and a warning row only when something needs fixing.
public struct PopoverView: View {
    @ObservedObject var engine: EngineModel
    var openSettings: () -> Void
    var fix: (FridayWarning) -> Void
    @State private var draft = ""
    @FocusState private var asking: Bool

    public init(engine: EngineModel, openSettings: @escaping () -> Void = {},
                fix: @escaping (FridayWarning) -> Void = { _ in }) {
        self.engine = engine
        self.openSettings = openSettings
        self.fix = fix
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            exchange
            askField
            if engine.otherFridayRunning {
                Divider().overlay(Color.line)
                TakeoverRow(engine: engine)
            } else if let problem = engine.problem {
                Divider().overlay(Color.line)
                problemRow(problem)
            } else if let warning = engine.warning {
                Divider().overlay(Color.line)
                warningRow(warning)
            }
        }
        .padding(Space.l)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(engine.state.label).monoLabel(11, medium: true).foregroundStyle(Color.ink2)
                .lineLimit(1)
            Spacer(minLength: Space.s)
            Button(action: engine.togglePause) {
                Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .help(engine.state == .paused ? "Resume listening (⇧⌘M)" : "Pause listening (⇧⌘M)")
            .accessibilityLabel(engine.state == .paused ? "Resume listening" : "Pause listening")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
    }

    @ViewBuilder private var exchange: some View {
        if engine.heard.isEmpty && engine.reply.isEmpty {
            Text("Say “hey Friday”, then just talk.")
                .font(FridayFont.body).foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(engine.heard)”").font(FridayFont.body).foregroundStyle(Color.muted).lineLimit(2)
                Text(engine.reply).font(FridayFont.body).foregroundStyle(Color.ink).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private var askField: some View {
        HStack(spacing: Space.s) {
            TextField("Ask Friday…", text: $draft)
                .textFieldStyle(.plain).font(FridayFont.body).focused($asking)
                .onSubmit(send)
            Text("↩").monoLabel(11).foregroundStyle(Color.muted).accessibilityHidden(true)
        }
        .padding(.horizontal, Space.m)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: Radius.input).fill(Color.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: Radius.input)
            .strokeBorder(asking ? Color.fridayAccent : Color.line, lineWidth: 1))
        .disabled(engine.state == .paused || engine.state == .error)
        .accessibilityLabel("Ask Friday by typing")
    }

    private func warningRow(_ warning: FridayWarning) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(warning.isError ? Color.alert : Color.warn).font(.system(size: 11))
            Text(warning.message).font(.system(size: 12)).foregroundStyle(Color.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Button(warning.fix) { fix(warning) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.fridayAccent)
        }
    }

    private func problemRow(_ problem: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Color.alert)
                .font(.system(size: 11))
            Text(problem).font(.system(size: 12)).foregroundStyle(Color.ink2).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            Button("Try again") { engine.restartEngine() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.fridayAccent)
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .paused, .error: .alert
        case .starting, .loading, .warmingClaude: .warn
        default: engine.conversation ? .fridayAccent : .muted
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        engine.ask(text)
        draft = ""
    }
}
