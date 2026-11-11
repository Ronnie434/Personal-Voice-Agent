import AppKit
import CoreAudio
import IOKit.ps
import ServiceManagement

/// Things outside Friday that it has to react to: the Mac waking, the default
/// microphone or speaker changing, and switching between battery and mains.
@MainActor
public final class SystemEvents {
    public var onWake: () -> Void = {}
    public var onAudioDeviceChange: () -> Void = {}
    public var onPowerChange: (_ onBattery: Bool) -> Void = { _ in }

    private var powerSource: CFRunLoopSource?
    private var lastOnBattery: Bool?
    private var deviceDebounce: Task<Void, Never>?

    public init() {}

    public func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onWake() } }

        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.audioDeviceChanged() }
            }
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let events = Unmanaged<SystemEvents>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { events.powerChanged() } }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerChanged()
    }

    /// Re-send the current power state (after the setting was switched on or off).
    public func reportPower() {
        lastOnBattery = nil
        powerChanged()
    }

    public static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    private func powerChanged() {
        let now = Self.onBattery
        guard now != lastOnBattery else { return }
        lastOnBattery = now
        onPowerChange(now)
    }

    private func audioDeviceChanged() {
        // Plugging in a headset fires several changes in a row.
        deviceDebounce?.cancel()
        deviceDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.onAudioDeviceChange()
        }
    }
}

/// "Open Friday when I log in". Only a real app bundle can register.
@MainActor
public enum LoginItem {
    public static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public static var enabled: Bool {
        available && SMAppService.mainApp.status == .enabled
    }

    /// Returns what went wrong, or nil.
    @discardableResult
    public static func set(_ on: Bool) -> String? {
        guard available else { return "Build and install Friday.app first." }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
