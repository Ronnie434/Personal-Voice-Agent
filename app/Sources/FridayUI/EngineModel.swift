import Foundation
import SwiftUI

/// What Friday is doing, as the engine reports it (protocol v1 `state`).
public enum FridayState: String, CaseIterable, Sendable {
    case starting, loading, warmingClaude = "warming_claude"
    case listening, hearing, thinking, speaking, paused, error

    public var label: String {
        switch self {
        case .starting, .loading: "Starting"
        case .warmingClaude: "Waking Claude"
        case .listening: "Listening for “hey Friday”"
        case .hearing: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .paused: "Paused"
        case .error: "Not running"
        }
    }
}

/// A problem the user can fix (protocol v1 `warning`).
public enum FridayWarning: String, CaseIterable, Sendable {
    case ttsQuota = "tts_quota", ttsAuth = "tts_auth", claudeAuth = "claude_auth"
    case claudeMissing = "claude_missing", micDenied = "mic_denied"
    case deviceLost = "device_lost", modelMissing = "model_missing"

    public var message: String {
        switch self {
        case .ttsQuota: "ElevenLabs is out of credits. Using the backup voice."
        case .ttsAuth: "The ElevenLabs key was rejected. Using the backup voice."
        case .claudeAuth: "Claude is signed out."
        case .claudeMissing: "Claude Code isn’t installed."
        case .micDenied: "Friday can’t use the microphone."
        case .deviceLost: "The microphone was disconnected."
        case .modelMissing: "The speech model isn’t downloaded."
        }
    }

    public var fix: String {
        switch self {
        case .ttsQuota, .ttsAuth: "Voice settings"
        case .claudeAuth: "Sign in"
        case .claudeMissing: "Install"
        case .micDenied: "Open Privacy settings"
        case .deviceLost: "Choose microphone"
        case .modelMissing: "Download"
        }
    }

    public var isError: Bool { self == .micDenied || self == .claudeMissing || self == .claudeAuth }
}

/// Everything the UI shows. The real one is fed by the engine over the socket
/// (M2); `FakeEngine` plays a scripted conversation for the prototype.
@MainActor
open class EngineModel: ObservableObject {
    @Published public var state: FridayState = .listening
    /// A conversation is open: the HUD shows, no wake phrase needed.
    @Published public var conversation = false
    @Published public var micLevel: Double = 0
    @Published public var outLevel: Double = 0
    @Published public var heard = ""
    @Published public var reply = ""
    @Published public var warning: FridayWarning?
    /// Why the engine isn't running, when it isn't. Shown instead of a warning.
    @Published public var problem: String?
    @Published public var inputs: [String] = []
    @Published public var outputs: [String] = []

    public init() {}

    /// A Friday started from a terminal is running; ours waits until the user
    /// chooses to stop that one.
    @Published public var otherFridayRunning = false

    open func restartEngine() {}
    /// Stop the other Friday and start this one.
    open func takeOver() {}

    open func togglePause() { state = state == .paused ? .listening : .paused; conversation = false }
    open func ask(_ text: String) {}
    open func interrupt() {}
}

/// A scripted engine: loops through one exchange so every state can be seen.
@MainActor
public final class FakeEngine: EngineModel {
    private var script: Task<Void, Never>?

    public init(autoplay: Bool = true) {
        super.init()
        heard = "what’s on my calendar today?"
        reply = "You have two meetings. Design review at eleven, then a one to one with Priya at three."
        if autoplay { play() }
    }

    public func play() {
        script?.cancel()
        script = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.exchange(heard: "what’s on my calendar today?",
                                    reply: "You have two meetings. Design review at eleven, then a one to one with Priya at three.")
                await self.exchange(heard: "any failing CI on my pull requests?",
                                    reply: "One. The checkout fix has a failing lint job, everything else is green.")
            }
        }
    }

    private func exchange(heard text: String, reply answer: String) async {
        set(.listening, conversation: false)
        await pause(3)
        set(.hearing, conversation: true)
        await levels(seconds: 2.2) { self.micLevel = $0 }
        heard = text
        set(.thinking, conversation: true)
        await pause(2.4)
        reply = answer
        set(.speaking, conversation: true)
        await levels(seconds: 3.5) { self.outLevel = $0 }
        set(.listening, conversation: true)
        await pause(2.5)
    }

    private func set(_ new: FridayState, conversation open: Bool) {
        guard state != .paused else { return }
        withAnimation(Motion.spring) { state = new; conversation = open }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        while state == .paused && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
    }

    private func levels(seconds: Double, _ apply: @escaping (Double) -> Void) async {
        let steps = Int(seconds * 20)
        for step in 0..<steps where !Task.isCancelled && state != .paused {
            let t = Double(step) / 20
            apply(max(0, 0.45 + 0.3 * sin(t * 9) + 0.2 * sin(t * 23 + 1)))
            try? await Task.sleep(for: .milliseconds(50))
        }
        apply(0)
    }

    public override func togglePause() {
        withAnimation(Motion.spring) {
            state = state == .paused ? .listening : .paused
            conversation = false
            micLevel = 0; outLevel = 0
        }
    }

    public override func ask(_ text: String) {
        script?.cancel()
        script = Task { [weak self] in
            guard let self else { return }
            self.heard = text
            self.set(.thinking, conversation: true)
            await self.pause(1.5)
            self.reply = "This is the prototype, so I can’t look that up yet."
            self.set(.speaking, conversation: true)
            await self.levels(seconds: 2.5) { self.outLevel = $0 }
            self.set(.listening, conversation: true)
            await self.pause(2)
            self.play()
        }
    }
}
