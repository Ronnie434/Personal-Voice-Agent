import SwiftUI

/// First run: one step per screen, one sentence, one control, a live check.
public struct SetupView: View {
    public enum Step: Int, CaseIterable {
        case welcome, claude, voice, microphone, model, wake, done
    }

    public enum Check: Equatable { case waiting, running, ok(String), failed(String, fix: String) }

    /// What setup checks on this Mac. The prototype and screenshots use `.example`.
    public struct Checks {
        public var claude: () async -> Check
        public var microphone: () async -> Check
        public var model: () async -> Check
        public var fix: (Step) -> Void
        /// Start the engine, so the wake phrase can be tried before setup ends.
        public var startEngine: () -> Void = {}

        public init(claude: @escaping () async -> Check, microphone: @escaping () async -> Check,
                    model: @escaping () async -> Check, startEngine: @escaping () -> Void = {},
                    fix: @escaping (Step) -> Void) {
            self.startEngine = startEngine
            self.claude = claude
            self.microphone = microphone
            self.model = model
            self.fix = fix
        }

        public static let example = Checks(
            claude: { .ok("Claude Code found, signed in") }, microphone: { .ok("Friday can hear you") },
            model: { .ok("Speech model is on this Mac") }, fix: { _ in })
    }

    @ObservedObject var engine: EngineModel
    @ObservedObject var store: SettingsStore
    @State var step: Step
    @State private var key = ""
    @State private var results: [Step: Check]
    @State private var wakeCount: Int
    @State private var launchAtLogin = LoginItem.enabled
    var checks: Checks
    var finish: () -> Void

    public init(engine: EngineModel, store: SettingsStore, checks: Checks = .example, step: Step = .welcome,
                results: [Step: Check] = [:], wakeCount: Int = 0, finish: @escaping () -> Void = {}) {
        self.engine = engine
        self.store = store
        self.checks = checks
        _step = State(initialValue: step)
        _results = State(initialValue: results)
        _wakeCount = State(initialValue: wakeCount)
        self.finish = finish
    }

    private func runCheck() async {
        let check: (() async -> Check)? = switch step {
        case .claude: checks.claude
        case .microphone: checks.microphone
        case .model: checks.model
        default: nil
        }
        guard let check else { return }
        if results[step] == nil { results[step] = .running }
        // Checked again every few seconds, so a fix made elsewhere shows up by itself.
        while !Task.isCancelled {
            results[step] = await check()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            progress
            VStack(alignment: .leading, spacing: Space.l) {
                Spacer(minLength: 0)
                Text(eyebrowText).eyebrow()
                Text(title).font(FridayFont.setupTitle).tracking(-0.84).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sentence).font(.system(size: 15)).foregroundStyle(Color.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                control.padding(.top, Space.s)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            footer
        }
        .frame(width: 560, height: 640)
        .background(Color.surface)
        .task(id: step) {
            if step == .wake { checks.startEngine() }
            await runCheck()
        }
        .onChange(of: engine.heard) { _, _ in
            // Each time Friday hears its name, a conversation request arrives.
            if step == .wake && wakeCount < 3 { withAnimation(Motion.spring) { wakeCount += 1 } }
        }
    }

    private var progress: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.line)
                Rectangle().fill(Color.ink)
                    .frame(width: proxy.size.width * CGFloat(step.rawValue + 1) / CGFloat(Step.allCases.count))
            }
        }
        .frame(height: 2)
        .animation(Motion.spring, value: step)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { move(-1) }.buttonStyle(PillButtonStyle(.secondary, height: 36))
            }
            Spacer()
            if step == .voice {
                Button("Skip, use the Mac’s voice") {
                    store.settings.voice = "local"
                    store.settings.backupVoice = "system"
                    move(1)
                }
                    .buttonStyle(.plain).font(FridayFont.button).foregroundStyle(Color.muted)
                    .padding(.trailing, Space.m)
            }
            Button(step == .done ? "Start Friday" : step == .welcome ? "Get started" : "Continue") {
                if step == .voice && !key.isEmpty { store.setElevenLabsKey(key); key = "" }
                step == .done ? finish() : move(1)
            }
            .buttonStyle(PillButtonStyle(.primary, height: 36))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 56).padding(.bottom, 40)
    }

    private func move(_ by: Int) {
        if let next = Step(rawValue: step.rawValue + by) { withAnimation(Motion.spring) { step = next } }
    }

    private var eyebrowText: String {
        switch step {
        case .welcome: "Friday for Mac"
        case .claude: "Claude Code"
        case .voice: "Voice"
        case .microphone: "Microphone"
        case .model: "Speech model"
        case .wake: "Wake phrase"
        case .done: "Ready"
        }
    }

    private var title: String {
        switch step {
        case .welcome: "Say “hey Friday”.\nThen just talk."
        case .claude: "Friday works through your Claude Code."
        case .voice: "Give Friday a voice."
        case .microphone: "Let Friday hear you."
        case .model: "Speech stays on this Mac."
        case .wake: "Say “hey Friday” three times."
        case .done: "Friday is in your menu bar."
        }
    }

    private var sentence: String {
        switch step {
        case .welcome: "A hands-free assistant that lives in your menu bar, does things on your Mac and talks back. Setup takes a few minutes."
        case .claude: "It uses the Claude Code already signed in on this Mac. Friday never sees your Claude password."
        case .voice: "Paste an ElevenLabs key for a natural voice. It is kept in your Keychain and only ever sent to ElevenLabs."
        case .microphone: "Friday listens for its name and nothing else. One shortcut, ⇧⌘M, mutes it at any time."
        case .model: "A 1.5 GB model turns what you say into text here, not in the cloud. It is downloaded once, the first time Friday starts."
        case .wake: "This checks that Friday can hear its name in this room. It will answer each time; that is fine. You can skip this."
        case .done: "Click the icon to see what Friday heard, type a request, or pause it. Talk to it from anywhere."
        }
    }

    @ViewBuilder private var control: some View {
        switch step {
        case .welcome:
            HStack(spacing: Space.m) {
                Orb(state: .hearing, level: 0.7, size: 30, color: .ink)
                Text("LISTENING FOR ITS NAME").monoLabel(11, medium: true).foregroundStyle(Color.muted)
            }
        case .claude:
            CheckRow(check: results[.claude] ?? .running) { checks.fix(.claude) }
        case .voice:
            VStack(alignment: .leading, spacing: Space.m) {
                SecureField("ElevenLabs API key", text: $key)
                    .textFieldStyle(.plain).font(FridayFont.mono(12))
                    .padding(.horizontal, Space.m).frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: Radius.input).strokeBorder(Color.line, lineWidth: 1))
                CheckRow(check: store.hasElevenLabsKey ? .ok("A key is already in your Keychain") : .waiting,
                         waiting: key.isEmpty ? "No key yet. Friday will use a voice on this Mac." : "Saved to your Keychain when you continue")
            }
        case .microphone:
            VStack(alignment: .leading, spacing: Space.m) {
                LevelMeter(level: engine.micLevel)
                CheckRow(check: results[.microphone] ?? .running) { checks.fix(.microphone) }
            }
        case .model:
            CheckRow(check: results[.model] ?? .running) { checks.fix(.model) }
        case .wake:
            VStack(alignment: .leading, spacing: Space.l) {
                if engine.otherFridayRunning {
                    TakeoverRow(engine: engine)
                } else {
                    HStack(spacing: Space.m) {
                        ForEach(0..<3, id: \.self) { index in
                            ZStack {
                                Circle().strokeBorder(index < wakeCount ? Color.ink : Color.line, lineWidth: 1.5)
                                if index < wakeCount {
                                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.ink)
                                }
                            }
                            .frame(width: 40, height: 40)
                        }
                        Text(wakeLabel).monoLabel(11, medium: true).foregroundStyle(Color.muted)
                            .padding(.leading, Space.s)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Heard \(wakeCount) of 3")
                    if let problem = engine.problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(Color.alert)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: Space.l) {
                Toggle("Open Friday when I log in", isOn: $launchAtLogin)
                    .toggleStyle(.switch).tint(Color.fridayAccent).font(FridayFont.body)
                    .disabled(!LoginItem.available)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
                doneHint
            }
        }
    }

    private var wakeLabel: String {
        switch engine.state {
        case .starting, .loading, .warmingClaude: "FRIDAY IS STARTING…"
        case .error: "FRIDAY ISN’T RUNNING"
        default: "HEARD \(wakeCount) OF 3"
        }
    }

    private var doneHint: some View {
        HStack(spacing: Space.m) {
            Shortcut("⇧⌘M")
            Text("pauses and resumes listening, from anywhere.").font(FridayFont.body).foregroundStyle(Color.muted)
        }
    }
}

struct CheckRow: View {
    var check: SetupView.Check
    var waiting = "Waiting"
    var fix: () -> Void = {}

    var body: some View {
        HStack(spacing: Space.s) {
            switch check {
            case .waiting:
                Circle().strokeBorder(Color.line, lineWidth: 1.5).frame(width: 16, height: 16)
                Text(waiting).foregroundStyle(Color.muted)
            case .running:
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
                Text("Checking…").foregroundStyle(Color.muted)
            case .ok(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ink)
                Text(text).foregroundStyle(Color.ink2)
            case .failed(let text, let fix):
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.alert)
                Text(text).foregroundStyle(Color.ink2)
                Button(fix, action: self.fix).buttonStyle(PillButtonStyle(.secondary, height: 26))
            }
        }
        .font(FridayFont.body)
    }
}

struct LevelMeter: View {
    var level: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<32, id: \.self) { bar in
                Capsule().fill(Double(bar) / 32 < level ? Color.ink : Color.line)
                    .frame(width: 4, height: 18)
            }
        }
        .animation(Motion.quick, value: level)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
