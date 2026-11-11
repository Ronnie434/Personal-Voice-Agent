import Foundation
import FridayCore
import SwiftUI

/// The user's settings: saved to settings.json on every change, with the
/// ElevenLabs key in the Keychain. Tells its owner when the engine needs a restart.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: FridaySettings {
        didSet {
            guard settings != oldValue else { return }
            try? SettingsFile.save(settings, to: url)
            if settings.needsRestart(comparedTo: oldValue) { scheduleRestart() }
        }
    }
    /// Whether a key is stored. The key itself is never held in the UI.
    @Published public private(set) var hasElevenLabsKey: Bool

    private let url: URL
    private let keychain: KeychainItem
    private var pending: Task<Void, Never>?
    /// Called a moment after the last change that the engine has to pick up.
    public var onEngineSettingsChanged: (() -> Void)?

    public init(url: URL = FridayPaths.settings,
                keychain: KeychainItem = KeychainItem(service: "com.ronnie434.Friday", account: "elevenlabs")) {
        self.url = url
        self.keychain = keychain
        settings = SettingsFile.load(from: url)
        hasElevenLabsKey = keychain.read()?.isEmpty == false
    }

    public func setElevenLabsKey(_ key: String) {
        keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
        hasElevenLabsKey = keychain.read()?.isEmpty == false
        scheduleRestart()
    }

    /// What the engine is sent when it connects.
    public func engineSettings() -> [String: String] {
        settings.engineSettings(elevenLabsKey: keychain.read())
    }

    private func scheduleRestart() {
        pending?.cancel()
        pending = Task { [weak self] in
            // Wait for typing and slider drags to finish.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.onEngineSettingsChanged?()
        }
    }
}
