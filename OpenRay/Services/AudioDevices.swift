import CoreAudio
import Foundation

enum AudioScope: String, CaseIterable, Sendable {
    case output, input

    var title: String { self == .output ? "Output" : "Input" }
}

/// A sound device, as Core Audio lists it.
struct AudioDevice: Identifiable, Hashable, Sendable {
    enum Transport: String, Sendable {
        case builtIn, usb, bluetooth, airPlay, hdmi, displayPort, thunderbolt, virtual, aggregate, other
    }

    /// Core Audio's object ID. Changes across reboots; `uid` doesn't.
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: Transport

    func symbol(for scope: AudioScope) -> String {
        switch (transport, scope) {
        case (.bluetooth, _): "headphones"
        case (.airPlay, _): "airplayaudio"
        case (.hdmi, .output), (.displayPort, .output): "tv"
        case (.usb, _), (.thunderbolt, _): scope == .output ? "hifispeaker" : "mic"
        case (_, .input): "mic"
        default: "speaker.wave.2"
        }
    }
}

enum AudioDeviceError: LocalizedError, Equatable {
    case noDevice(AudioScope)
    case noVolumeControl
    case noMuteControl
    case failed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDevice(.output): "No sound output device is available."
        case .noDevice(.input): "No microphone is available."
        case .noVolumeControl: "This device has no volume control."
        case .noMuteControl: "This device can't be muted."
        case .failed(let status): "macOS couldn't change the sound setting (error \(status))."
        }
    }
}

/// Lists sound devices and reads or changes their defaults, volume and mute.
/// `CoreAudioDevices` is the real one; tests use a fake and never change the
/// user's sound.
@MainActor
protocol AudioDeviceControlling: AnyObject {
    func devices(for scope: AudioScope) -> [AudioDevice]
    func defaultDevice(for scope: AudioScope) -> AudioDevice?
    func setDefaultDevice(_ device: AudioDevice, for scope: AudioScope) throws
    /// 0...1, or nil when the device has no volume control.
    func volume(of device: AudioDevice, scope: AudioScope) -> Double?
    func setVolume(_ volume: Double, of device: AudioDevice, scope: AudioScope) throws
    func isMuted(_ device: AudioDevice, scope: AudioScope) -> Bool?
    func setMuted(_ muted: Bool, of device: AudioDevice, scope: AudioScope) throws
    func canSetVolume(of device: AudioDevice, scope: AudioScope) -> Bool
    func canMute(_ device: AudioDevice, scope: AudioScope) -> Bool
}

// MARK: - Volume logic

/// Volume Up, Down, Set and Toggle Mute on the default output, in the same
/// sixteen steps as the keyboard's volume keys.
@MainActor
struct VolumeControl {
    static let step = 1.0 / 16

    let audio: any AudioDeviceControlling

    static func stepped(_ level: Double, up: Bool) -> Double {
        let steps = (level / step).rounded()
        return min(max((steps + (up ? 1 : -1)) * step, 0), 1)
    }

    func apply(_ change: VolumeChange) throws -> SystemActionResult {
        guard let device = audio.defaultDevice(for: .output) else { throw AudioDeviceError.noDevice(.output) }
        switch change {
        case .toggleMute:
            guard audio.canMute(device, scope: .output), let muted = audio.isMuted(device, scope: .output) else {
                throw AudioDeviceError.noMuteControl
            }
            try audio.setMuted(!muted, of: device, scope: .output)
            return .muted(!muted)
        case .up, .down, .set:
            guard audio.canSetVolume(of: device, scope: .output), let level = audio.volume(of: device, scope: .output)
            else { throw AudioDeviceError.noVolumeControl }
            let target: Double
            switch change {
            case .up: target = Self.stepped(level, up: true)
            case .down: target = Self.stepped(level, up: false)
            case .set(let value): target = min(max(value, 0), 1)
            case .toggleMute: target = level
            }
            try audio.setVolume(target, of: device, scope: .output)
            // Raising the volume unmutes, as the volume keys do.
            var muted = audio.isMuted(device, scope: .output) ?? false
            if muted, target > 0, change != .down, audio.canMute(device, scope: .output) {
                try audio.setMuted(false, of: device, scope: .output)
                muted = false
            }
            return .volume(target, muted: muted)
        }
    }
}

/// Toggle Microphone Mute. Uses the input's mute control, or turns its volume
/// to zero and back when it has none.
@MainActor
final class MicrophoneMuteControl {
    static let fallbackVolume = 0.75

    let audio: any AudioDeviceControlling
    /// The level to return to when the microphone was muted by volume.
    private(set) var restoreVolume: Double?

    init(audio: any AudioDeviceControlling) {
        self.audio = audio
    }

    /// Returns whether the microphone is now muted.
    func toggle() throws -> Bool {
        guard let device = audio.defaultDevice(for: .input) else { throw AudioDeviceError.noDevice(.input) }
        if audio.canMute(device, scope: .input), let muted = audio.isMuted(device, scope: .input) {
            try audio.setMuted(!muted, of: device, scope: .input)
            return !muted
        }
        guard audio.canSetVolume(of: device, scope: .input), let level = audio.volume(of: device, scope: .input) else {
            throw AudioDeviceError.noMuteControl
        }
        if level > 0 {
            try audio.setVolume(0, of: device, scope: .input)
            restoreVolume = level
            return true
        }
        try audio.setVolume(restoreVolume ?? Self.fallbackVolume, of: device, scope: .input)
        restoreVolume = nil
        return false
    }
}

// MARK: - Core Audio

/// The real sound devices. Reading is harmless; every change checks `SideEffectGuard`.
@MainActor
final class CoreAudioDevices: AudioDeviceControlling {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    nonisolated init() {}

    func devices(for scope: AudioScope) -> [AudioDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { hasStreams($0, scope: scope) && !isHidden($0) }.compactMap { device($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func defaultDevice(for scope: AudioScope) -> AudioDevice? {
        let selector = scope == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        guard let id: AudioObjectID = read(Self.system, Self.address(selector), initial: 0), id != 0 else { return nil }
        return device(id)
    }

    func setDefaultDevice(_ device: AudioDevice, for scope: AudioScope) throws {
        try SideEffectGuard.check("changing the sound device")
        if scope == .output {
            try write(Self.system, Self.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
            // Alerts follow the output, as when choosing it in Control Center.
            try? write(Self.system, Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice), device.id)
        } else {
            try write(Self.system, Self.address(kAudioHardwarePropertyDefaultInputDevice), device.id)
        }
    }

    func volume(of device: AudioDevice, scope: AudioScope) -> Double? {
        let levels = volumeElements(device.id, scope: scope).compactMap { element -> Float32? in
            read(device.id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element), initial: 0)
        }
        guard !levels.isEmpty else { return nil }
        return Double(levels.reduce(0, +)) / Double(levels.count)
    }

    func setVolume(_ volume: Double, of device: AudioDevice, scope: AudioScope) throws {
        try SideEffectGuard.check("changing the volume")
        let elements = volumeElements(device.id, scope: scope)
        guard !elements.isEmpty else { throw AudioDeviceError.noVolumeControl }
        let value = Float32(min(max(volume, 0), 1))
        for element in elements {
            try write(device.id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element), value)
        }
    }

    func isMuted(_ device: AudioDevice, scope: AudioScope) -> Bool? {
        let value: UInt32? = read(device.id, Self.address(kAudioDevicePropertyMute, scope: scope), initial: 0)
        return value.map { $0 != 0 }
    }

    func setMuted(_ muted: Bool, of device: AudioDevice, scope: AudioScope) throws {
        try SideEffectGuard.check("muting a sound device")
        try write(device.id, Self.address(kAudioDevicePropertyMute, scope: scope), UInt32(muted ? 1 : 0))
    }

    func canSetVolume(of device: AudioDevice, scope: AudioScope) -> Bool {
        !volumeElements(device.id, scope: scope).isEmpty
    }

    func canMute(_ device: AudioDevice, scope: AudioScope) -> Bool {
        isSettable(device.id, Self.address(kAudioDevicePropertyMute, scope: scope))
    }

    // MARK: Helpers

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioScope? = nil,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        let scopeValue: AudioObjectPropertyScope =
            switch scope {
            case .output: kAudioObjectPropertyScopeOutput
            case .input: kAudioObjectPropertyScopeInput
            case nil: kAudioObjectPropertyScopeGlobal
            }
        return AudioObjectPropertyAddress(mSelector: selector, mScope: scopeValue, mElement: element)
    }

    private func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? uid
        let transportValue: UInt32 = read(id, Self.address(kAudioDevicePropertyTransportType), initial: 0) ?? 0
        return AudioDevice(id: id, uid: uid, name: name, transport: Self.transport(transportValue))
    }

    private static func transport(_ value: UInt32) -> AudioDevice.Transport {
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI: .hdmi
        case kAudioDeviceTransportTypeDisplayPort: .displayPort
        case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .other
        }
    }

    private func hasStreams(_ id: AudioObjectID, scope: AudioScope) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private func isHidden(_ id: AudioObjectID) -> Bool {
        let value: UInt32? = read(id, Self.address(kAudioDevicePropertyIsHidden), initial: 0)
        return (value ?? 0) != 0
    }

    /// The main element when the device has a master control, else its stereo channels.
    private func volumeElements(_ id: AudioObjectID, scope: AudioScope) -> [AudioObjectPropertyElement] {
        let main = kAudioObjectPropertyElementMain
        if isSettable(id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: main)) {
            return [main]
        }
        var channels: [UInt32] = [1, 2]
        var address = Self.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: scope)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        var preferred: [UInt32] = [0, 0]
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &preferred) == noErr, preferred.allSatisfy({ $0 > 0 }) {
            channels = preferred
        }
        return channels.filter {
            isSettable(id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0))
        }
    }

    private func isSettable(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }

    private func read<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    private func write<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        guard status == noErr else { throw AudioDeviceError.failed(status) }
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
