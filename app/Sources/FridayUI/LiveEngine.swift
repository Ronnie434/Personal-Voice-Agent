import AppKit
import Foundation
import FridayCore
import SwiftUI

/// A value shared between the main thread and the supervisor's queue.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ new: Value) { lock.withLock { value = new } }
}

/// The real engine: a supervised Python process, reported over the socket.
@MainActor
public final class LiveEngine: EngineModel {
    private let store: SettingsStore
    private var supervisor: Supervisor!
    private let path: String
    private let extraEnvironment: [String: String]
    private let defaultDirectory: String
    /// What the next engine start will use: (checkout, settings to send).
    private let plan = Locked<(String, [String: String])>(("", [:]))

    /// - Parameter defaultDirectory: the checkout to run the engine from when
    ///   Settings doesn't name one.
    public init(store: SettingsStore, defaultDirectory: String, socketPath: String = FridayPaths.socket) {
        self.store = store
        self.defaultDirectory = defaultDirectory
        path = Machine.loginPath()
        // For trying the app without sound: passed straight through to the engine.
        let process = ProcessInfo.processInfo.environment
        extraEnvironment = process.filter { ["FRIDAY_NO_AUDIO", "CLAUDE_BIN", "FRIDAY_ENV_FILE"].contains($0.key) }
        super.init()
        state = .starting
        heard = ""
        reply = ""

        let path = path, extra = extraEnvironment, plan = plan
        refreshPlan()
        // These run on the supervisor's queue, so they read a snapshot, not the store.
        supervisor = Supervisor(
            socketPath: socketPath, logURL: FridayPaths.engineLog,
            launch: { Machine.engineLaunch(directory: plan.get().0, path: path, extra: extra) },
            settings: { plan.get().1 })
        supervisor.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
        supervisor.onStatus = { [weak self] status in MainActor.assumeIsolated { self?.handle(status) } }
        store.onEngineSettingsChanged = { [weak self] in self?.restartEngine() }
    }

    public var engineDirectory: String {
        store.settings.engineDirectory.isEmpty ? defaultDirectory : store.settings.engineDirectory
    }

    private func refreshPlan() { plan.set((engineDirectory, store.engineSettings())) }

    /// Asked just before the engine starts: is the microphone allowed? (The app
    /// shows the system prompt here, as Friday.)
    public var microphoneAllowed: () async -> Bool = { true }

    /// Start the engine, unless another Friday is listening or the mic is off limits.
    public func start() async {
        // Two Fridays would both answer. Wait for the user to pick this one.
        guard extraEnvironment["FRIDAY_NO_AUDIO"] == "1" || Machine.otherFridays().isEmpty else {
            otherFridayRunning = true
            withAnimation(Motion.spring) { state = .paused; conversation = false }
            return
        }
        otherFridayRunning = false
        guard await microphoneAllowed() else {
            warning = .micDenied
            withAnimation(Motion.spring) { state = .error }
            return
        }
        guard !started else { return }
        if warning == .micDenied { warning = nil }
        state = .starting
        refreshPlan()
        supervisor.start()
        started = true
    }

    public private(set) var started = false

    public override func takeOver() {
        let others = Machine.otherFridays()
        for pid in others { kill(pid, SIGTERM) }
        Task {
            // Give it a moment to let go of the microphone, then make sure.
            try? await Task.sleep(for: .seconds(1.5))
            for pid in Machine.otherFridays() { kill(pid, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(300))
            await start()
        }
    }

    /// Restart once Friday is between conversations (after sleep, or when the
    /// microphone or speaker changed), so nothing is cut off mid-sentence.
    public func restartWhenIdle(reason: String) {
        guard started, problem == nil else { return }
        pendingRestart?.cancel()
        pendingRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while let self, !Task.isCancelled, self.conversation, self.state != .paused {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.restartEngine()
        }
    }

    private var pendingRestart: Task<Void, Never>?

    /// Pause or resume on the app's own initiative (battery), without fighting
    /// a pause the user chose.
    public func setAutoPaused(_ paused: Bool) {
        guard started else { return }
        if paused, state != .paused { autoPaused = true; supervisor.send(.pause) }
        if !paused, autoPaused { autoPaused = false; if state == .paused { supervisor.send(.resume) } }
    }

    private var autoPaused = false
    public func stop() { supervisor.stop(); started = false }

    public override func restartEngine() {
        problem = nil
        warning = nil
        state = .starting
        conversation = false
        guard started else { Task { await start() }; return }
        refreshPlan()
        supervisor.stop()
        supervisor.start()
    }

    public override func togglePause() {
        guard started else { return }
        autoPaused = false  // the user has taken over the pause
        supervisor.send(state == .paused ? .resume : .pause)
    }

    public override func ask(_ text: String) { supervisor.send(.ask(text)) }
    public override func interrupt() { supervisor.send(.interrupt) }

    /// FRIDAY_TRACE=1 prints what the UI model shows; FRIDAY_TRIAL_ASK sends one
    /// typed request when the engine is first ready. For trial runs without sound.
    private let trace = ProcessInfo.processInfo.environment["FRIDAY_TRACE"] == "1"
    private var trialAsk = ProcessInfo.processInfo.environment["FRIDAY_TRIAL_ASK"]

    private func handle(_ event: EngineEvent) {
        defer {
            if trace, event != .heartbeat {
                FileHandle.standardError.write(Data(
                    "ui state=\(state.rawValue) conversation=\(conversation) heard=\(heard) reply=\(reply) warning=\(warning?.rawValue ?? "-")\n".utf8))
            }
            if case .state("listening", _) = event, let text = trialAsk {
                trialAsk = nil
                ask(text)
            }
        }
        switch event {
        case .state(let name, let open):
            let new = FridayState(rawValue: name) ?? .listening
            if open && !conversation && store.settings.openChime { NSSound(named: "Pop")?.play() }
            if !open && conversation && store.settings.closeChime { NSSound(named: "Bottle")?.play() }
            withAnimation(Motion.spring) { state = new; conversation = open }
            if new != .hearing { micLevel = 0 }
            if new != .speaking { outLevel = 0 }
        case .levels(let mic, let out):
            micLevel = mic
            outLevel = out
        case .heard(let text):
            heard = text
            reply = ""
        case .reply(let text, _):
            reply = text
        case .warning(let code):
            warning = FridayWarning(rawValue: code)
        case .devices(let ins, let outs, _, _):
            inputs = ins
            outputs = outs
        case .hello, .heartbeat, .unknown:
            break
        }
    }

    private func handle(_ status: Supervisor.Status) {
        switch status {
        case .starting, .restarting:
            withAnimation(Motion.spring) { state = .starting; conversation = false }
        case .running:
            problem = nil
        case .failed(let why):
            problem = why
            withAnimation(Motion.spring) { state = .error; conversation = false }
        case .stopped:
            break
        }
    }
}
