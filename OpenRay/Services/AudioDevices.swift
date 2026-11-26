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
    /// Gain controls that can silence the device: the main element when it has
    /// one, else each channel that has its own.
    func gainElements(of device: AudioDevice, scope: AudioScope) -> [UInt32]
    /// True when `gainElements` covers every channel the device streams, so zero
    /// gain on all of them is silence.
    func gainCoversAllChannels(of device: AudioDevice, scope: AudioScope) -> Bool
    func gain(of device: AudioDevice, scope: AudioScope, element: UInt32) -> Double?
    func setGain(_ gain: Double, of device: AudioDevice, scope: AudioScope, element: UInt32) throws
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

/// Toggle Microphone Mute, across every input so an app that picked another
/// microphone directly is muted too. Each input uses its mute control; one
/// without uses zero gain, but only when gain covers every channel and reads
/// back as silent. Gains are remembered per device and channel, so unmuting
/// restores each microphone's own levels.
@MainActor
final class MicrophoneMuteControl {
    struct Outcome: Equatable, Sendable {
        /// The state every input was asked to take.
        var muted: Bool
        /// Inputs now in that state.
        var changed: [String]
        /// Inputs that couldn't change, by name.
        var unchanged: [String]
    }

    let audio: any AudioDeviceControlling
    /// Device UID → channel element → gain before muting.
    private(set) var savedGains: [String: [UInt32: Double]] = [:]

    init(audio: any AudioDeviceControlling) {
        self.audio = audio
    }

    /// Mutes every input when any of them is live; otherwise unmutes them all.
    func toggle() throws -> Outcome {
        let inputs = audio.devices(for: .input)
        guard !inputs.isEmpty else { throw AudioDeviceError.noDevice(.input) }
        let muting = inputs.contains { isLive($0) }
        var outcome = Outcome(muted: muting, changed: [], unchanged: [])
        for device in inputs {
            let done = (try? set(device, muted: muting)) ?? false
            if done { outcome.changed.append(device.name) } else { outcome.unchanged.append(device.name) }
        }
        guard !outcome.changed.isEmpty else { throw AudioDeviceError.noMuteControl }
        return outcome
    }

    /// Whether apps can hear this input: not muted, and not at zero gain on every channel.
    func isLive(_ device: AudioDevice) -> Bool {
        if audio.canMute(device, scope: .input), audio.isMuted(device, scope: .input) == true { return false }
        if audio.gainCoversAllChannels(of: device, scope: .input), isSilentByGain(device) { return false }
        return true
    }

    private func isSilentByGain(_ device: AudioDevice) -> Bool {
        let elements = audio.gainElements(of: device, scope: .input)
        return !elements.isEmpty
            && elements.allSatisfy { audio.gain(of: device, scope: .input, element: $0) == 0 }
    }

    /// Returns whether the device ended up in the requested state.
    private func set(_ device: AudioDevice, muted: Bool) throws -> Bool {
        if audio.canMute(device, scope: .input) {
            try audio.setMuted(muted, of: device, scope: .input)
            return audio.isMuted(device, scope: .input) == muted
        }
        guard audio.gainCoversAllChannels(of: device, scope: .input) else { return false }
        let elements = audio.gainElements(of: device, scope: .input)
        if muted {
            var saved = savedGains[device.uid] ?? [:]
            for element in elements {
                if let gain = audio.gain(of: device, scope: .input, element: element), gain > 0 {
                    saved[element] = gain
                }
            }
            savedGains[device.uid] = saved
            for element in elements { try audio.setGain(0, of: device, scope: .input, element: element) }
            return isSilentByGain(device)
        }
        // Only levels this control saved come back; another microphone's never do.
        guard let saved = savedGains[device.uid], !saved.isEmpty else { return !isSilentByGain(device) }
        for (element, gain) in saved { try audio.setGain(gain, of: device, scope: .input, element: element) }
        savedGains[device.uid] = nil
        return !isSilentByGain(device)
    }
}

// MARK: - Core Audio

/// The real sound devices. Reading is harmless; every change checks its `SideEffectGuard` first.
@MainActor
final class CoreAudioDevices: AudioDeviceControlling {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    let sideEffects: SideEffectGuard

    nonisolated init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

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
        try sideEffects.check("changing the sound device")
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
        try sideEffects.check("changing the volume")
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
        try sideEffects.check("muting a sound device")
        try write(device.id, Self.address(kAudioDevicePropertyMute, scope: scope), UInt32(muted ? 1 : 0))
    }

    func canSetVolume(of device: AudioDevice, scope: AudioScope) -> Bool {
        !volumeElements(device.id, scope: scope).isEmpty
    }

    func canMute(_ device: AudioDevice, scope: AudioScope) -> Bool {
        isSettable(device.id, Self.address(kAudioDevicePropertyMute, scope: scope))
    }

    func gainElements(of device: AudioDevice, scope: AudioScope) -> [UInt32] {
        let main = kAudioObjectPropertyElementMain
        if isSettable(device.id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: main)) {
            return [main]
        }
        let count = channelCount(device.id, scope: scope)
        guard count > 0 else { return [] }
        return (1...UInt32(count)).filter {
            isSettable(device.id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: $0))
        }
    }

    func gainCoversAllChannels(of device: AudioDevice, scope: AudioScope) -> Bool {
        let elements = gainElements(of: device, scope: scope)
        if elements == [kAudioObjectPropertyElementMain] { return true }
        let count = channelCount(device.id, scope: scope)
        return count > 0 && elements.count == count
    }

    func gain(of device: AudioDevice, scope: AudioScope, element: UInt32) -> Double? {
        let value: Float32? = read(
            device.id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element), initial: 0)
        return value.map(Double.init)
    }

    func setGain(_ gain: Double, of device: AudioDevice, scope: AudioScope, element: UInt32) throws {
        try sideEffects.check("changing a microphone's level")
        try write(
            device.id, Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element),
            Float32(min(max(gain, 0), 1)))
    }

    /// Channels across the device's streams in this direction.
    private func channelCount(_ id: AudioObjectID, scope: AudioScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
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

// MARK: - Defaults

enum AudioDeviceEnvironment {
    /// Core Audio in a normal launch; no devices and no changes in inert launches.
    static func makeDefault(sideEffects: SideEffectGuard = .current) -> any AudioDeviceControlling {
        let rule = sideEffects.effective
        return rule.isInert ? InertAudioDevices(sideEffects: rule) : CoreAudioDevices(sideEffects: rule)
    }
}

/// Lists nothing and refuses every change. The default in inert launches.
@MainActor
final class InertAudioDevices: AudioDeviceControlling {
    let sideEffects: SideEffectGuard

    nonisolated init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    func devices(for scope: AudioScope) -> [AudioDevice] { [] }
    func defaultDevice(for scope: AudioScope) -> AudioDevice? { nil }
    func setDefaultDevice(_ device: AudioDevice, for scope: AudioScope) throws { try refuse() }
    func volume(of device: AudioDevice, scope: AudioScope) -> Double? { nil }
    func setVolume(_ volume: Double, of device: AudioDevice, scope: AudioScope) throws { try refuse() }
    func isMuted(_ device: AudioDevice, scope: AudioScope) -> Bool? { nil }
    func setMuted(_ muted: Bool, of device: AudioDevice, scope: AudioScope) throws { try refuse() }
    func canSetVolume(of device: AudioDevice, scope: AudioScope) -> Bool { false }
    func canMute(_ device: AudioDevice, scope: AudioScope) -> Bool { false }
    func gainElements(of device: AudioDevice, scope: AudioScope) -> [UInt32] { [] }
    func gainCoversAllChannels(of device: AudioDevice, scope: AudioScope) -> Bool { false }
    func gain(of device: AudioDevice, scope: AudioScope, element: UInt32) -> Double? { nil }
    func setGain(_ gain: Double, of device: AudioDevice, scope: AudioScope, element: UInt32) throws { try refuse() }

    private func refuse() throws {
        throw SideEffectGuard.Blocked(what: "changing sound settings", mode: sideEffects.mode)
    }
}
