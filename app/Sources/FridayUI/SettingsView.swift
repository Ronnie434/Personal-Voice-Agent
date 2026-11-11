import SwiftUI

/// Settings: a sidebar of six panes, each a native grouped form.
public struct SettingsView: View {
    public enum Pane: String, CaseIterable, Identifiable {
        case general = "General", voice = "Voice", listening = "Listening"
        case claude = "Claude", privacy = "Privacy & Safety", advanced = "Advanced"
        public var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .voice: "waveform"
            case .listening: "mic"
            case .claude: "sparkle"
            case .privacy: "hand.raised"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    @State var pane: Pane
    @ObservedObject var store: SettingsStore
    @ObservedObject var engine: EngineModel
    @State private var editingKey = false
    @State private var newKey = ""
    @State private var loginItem = LoginItem.enabled
    @State private var loginItemError: String?
    var openLog: () -> Void

    public init(store: SettingsStore, engine: EngineModel, pane: Pane = .general, openLog: @escaping () -> Void = {}) {
        _pane = State(initialValue: pane)
        self.store = store
        self.engine = engine
        self.openLog = openLog
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.line)
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.rawValue).font(FridayFont.heading).tracking(-0.17).foregroundStyle(Color.ink)
                    .padding(.horizontal, Space.xl).padding(.top, Space.xl).padding(.bottom, Space.xs)
                Form { content }.formStyle(.grouped).scrollContentBackground(.hidden)
                    .font(FridayFont.body)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.surface)
        }
        .frame(width: 680, height: 460)
        .tint(Color.fridayAccent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Friday").eyebrow().padding(.horizontal, Space.s).padding(.bottom, Space.s)
            ForEach(Pane.allCases) { item in
                Button { pane = item } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.rawValue)
                        Spacer(minLength: 0)
                    }
                    .font(FridayFont.button)
                    .foregroundStyle(pane == item ? Color.ink : Color.muted)
                    .padding(.horizontal, Space.s).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(pane == item ? Color.chip : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer()
            Text("VERSION 0.2 · LOCAL BUILD").monoLabel(9.5).foregroundStyle(Color.muted)
                .padding(.horizontal, Space.s)
        }
        .padding(Space.m).padding(.top, Space.s)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .glass(Rectangle())
    }

    @ViewBuilder private var content: some View {
        let settings = $store.settings
        switch pane {
        case .general:
            Section {
                Toggle("Open Friday when I log in", isOn: Binding(
                    get: { loginItem },
                    set: { on in loginItemError = LoginItem.set(on); loginItem = LoginItem.enabled }))
                    .disabled(!LoginItem.available)
                Toggle("Show Friday’s bars during a conversation", isOn: settings.showHUD)
                Toggle("Pause listening on battery", isOn: settings.pauseOnBattery)
            } footer: {
                if let loginItemError { Text(loginItemError).foregroundStyle(Color.alert) }
            }
            Section("Sounds") {
                Toggle("Chime when a conversation opens", isOn: settings.openChime)
                Toggle("Chime when it closes", isOn: settings.closeChime)
            }
            Section("Shortcuts") {
                LabeledContent("Pause listening") { Shortcut("⇧⌘M") }
            }
        case .voice:
            Section {
                Picker("Voice", selection: settings.voice) {
                    Text("ElevenLabs").tag("elevenlabs")
                    Text("Backup voice only").tag("local")
                }
                LabeledContent("ElevenLabs key") {
                    if editingKey {
                        HStack {
                            SecureField("Paste key", text: $newKey).textFieldStyle(.roundedBorder).frame(width: 180)
                            Button("Save") { store.setElevenLabsKey(newKey); newKey = ""; editingKey = false }
                                .disabled(newKey.isEmpty)
                            Button("Cancel") { newKey = ""; editingKey = false }
                        }
                    } else {
                        HStack {
                            Text(store.hasElevenLabsKey ? "IN KEYCHAIN" : "FROM THE CHECKOUT’S .ENV, IF ANY")
                                .monoLabel(11).foregroundStyle(Color.muted)
                            Button(store.hasElevenLabsKey ? "Change…" : "Add…") { editingKey = true }
                            if store.hasElevenLabsKey { Button("Remove") { store.setElevenLabsKey("") } }
                        }
                    }
                }
            }
            Section {
                Picker("Backup voice", selection: settings.backupVoice) {
                    Text("Kokoro (on this Mac)").tag("kokoro"); Text("Mac system voice").tag("system")
                }
            } footer: {
                Text("Used when ElevenLabs can’t be reached or runs out of credits.")
            }
        case .listening:
            Section {
                TextField("Wake word", text: settings.wakeWord)
                LabeledContent("Keep listening after a reply") {
                    HStack { Slider(value: settings.conversationSecs, in: 10...120, step: 10).frame(width: 150)
                        Text("\(Int(store.settings.conversationSecs)) S").monoLabel(11).foregroundStyle(Color.muted).frame(width: 40) }
                }
                Toggle("Talking over Friday interrupts it", isOn: settings.bargeIn)
            }
            Section("Devices") {
                Picker("Microphone", selection: settings.inputDevice) {
                    Text("System default").tag("")
                    ForEach(devices(engine.inputs, chosen: store.settings.inputDevice), id: \.self) { Text($0).tag($0) }
                }
                Picker("Speaker", selection: settings.outputDevice) {
                    Text("System default").tag("")
                    ForEach(devices(engine.outputs, chosen: store.settings.outputDevice), id: \.self) { Text($0).tag($0) }
                }
            }
        case .claude:
            Section {
                Picker("Model", selection: settings.claudeModel) {
                    Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus"); Text("Haiku").tag("haiku")
                }
                TextField("What Friday calls you", text: settings.userName)
            } footer: {
                Text("Changing anything here restarts Friday’s engine, so it forgets the current conversation.")
            }
        case .privacy:
            Section {
                Picker("Friday may act", selection: settings.permissionMode) {
                    Text("With Claude’s safety check").tag("auto")
                    Text("Only with allowed tools").tag("dontAsk")
                    Text("Without any check").tag("bypassPermissions")
                }
            } footer: {
                Text("Placing trades and moving money are always blocked. Friday asks before sending, deleting, pushing or buying.")
            }
            Section {
                LabeledContent("Microphone audio") { Text("NEVER LEAVES THIS MAC").monoLabel(11).foregroundStyle(Color.muted) }
                LabeledContent("What was said") { Text("KEPT IN THE ENGINE LOG").monoLabel(11).foregroundStyle(Color.muted) }
            }
        case .advanced:
            Section {
                TextField("Engine checkout", text: settings.engineDirectory, prompt: Text("The one this app was built from"))
                    .font(FridayFont.mono(11))
                LabeledContent("Speech model") { Text("whisper-large-v3-turbo").monoLabel(11).foregroundStyle(Color.muted) }
            } footer: {
                Text("The folder that holds agent.py. Friday runs the engine from there with uv.")
            }
            Section {
                LabeledContent("Engine log") { Button("Show in Finder", action: openLog) }
                LabeledContent("Engine") { Button("Restart") { engine.restartEngine() } }
            }
        }
    }

    /// The devices the engine found, plus the saved one if it is unplugged right now.
    private func devices(_ found: [String], chosen: String) -> [String] {
        chosen.isEmpty || found.contains(chosen) ? found : found + [chosen]
    }
}

struct Shortcut: View {
    var keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys).monoLabel(11, medium: true).foregroundStyle(Color.ink2)
            .padding(.horizontal, Space.s).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.chip))
    }
}
