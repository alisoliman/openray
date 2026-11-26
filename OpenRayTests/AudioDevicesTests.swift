import Foundation
import Testing

@testable import OpenRay

@MainActor
struct AudioDevicesTests {
    @Test func volumeStepsMatchTheKeyboardsSixteenSteps() {
        #expect(VolumeControl.stepped(0.5, up: true) == 0.5625)
        #expect(VolumeControl.stepped(0.5, up: false) == 0.4375)
        #expect(VolumeControl.stepped(1, up: true) == 1)
        #expect(VolumeControl.stepped(0, up: false) == 0)
        // Off-grid levels snap to the nearest step first.
        #expect(VolumeControl.stepped(0.52, up: true) == 0.5625)
        #expect(VolumeControl.stepped(0.03, up: false) == 0)
    }

    @Test func volumeUpRaisesTheDefaultOutputAndUnmutes() throws {
        let audio = FakeAudioDevices()
        audio.mutes["speakers.output"] = true
        let result = try VolumeControl(audio: audio).apply(.up)
        #expect(result == .volume(0.5625, muted: false))
        #expect(audio.changes == ["volume.speakers.output=0.5625", "mute.speakers.output=false"])
        // The headphones weren't the default and stay untouched.
        #expect(audio.volumes["headphones.output"] == 0.25)
    }

    @Test func volumeDownKeepsTheMuteState() throws {
        let audio = FakeAudioDevices()
        audio.mutes["speakers.output"] = true
        #expect(try VolumeControl(audio: audio).apply(.down) == .volume(0.4375, muted: true))
        #expect(audio.changes == ["volume.speakers.output=0.4375"])
    }

    @Test func settingTheVolumeClampsAndFollowsTheDefaultDevice() throws {
        let audio = FakeAudioDevices()
        audio.defaults[.output] = FakeAudioDevices.headphones
        let control = VolumeControl(audio: audio)
        #expect(try control.apply(.set(0.3)) == .volume(0.3, muted: false))
        #expect(try control.apply(.set(4)) == .volume(1, muted: false))
        #expect(try control.apply(.set(-1)) == .volume(0, muted: false))
        #expect(audio.volumes["headphones.output"] == 0)
        #expect(audio.volumes["speakers.output"] == 0.5)
    }

    @Test func toggleMuteFlipsTheOutput() throws {
        let audio = FakeAudioDevices()
        let control = VolumeControl(audio: audio)
        #expect(try control.apply(.toggleMute) == .muted(true))
        #expect(try control.apply(.toggleMute) == .muted(false))
    }

    @Test func missingDevicesAndControlsFailClearly() {
        let audio = FakeAudioDevices()
        audio.defaults[.output] = nil
        #expect(throws: AudioDeviceError.noDevice(.output)) { try VolumeControl(audio: audio).apply(.up) }
        audio.defaults[.output] = FakeAudioDevices.speakers
        audio.volumeless = ["speakers.output"]
        #expect(throws: AudioDeviceError.noVolumeControl) { try VolumeControl(audio: audio).apply(.set(0.5)) }
        audio.unmutable = ["speakers.output"]
        #expect(throws: AudioDeviceError.noMuteControl) { try VolumeControl(audio: audio).apply(.toggleMute) }
        #expect(audio.changes.isEmpty)
    }

    // MARK: Microphones

    @Test func microphoneMuteCoversEveryInputNotJustTheDefault() throws {
        let audio = FakeAudioDevices()
        audio.inputs = [FakeAudioDevices.microphone, FakeAudioDevices.usbMicrophone]
        let microphones = MicrophoneMuteControl(audio: audio)
        let muted = try microphones.toggle()
        #expect(muted == .init(muted: true, changed: ["MacBook Microphone", "USB Microphone"], unchanged: []))
        #expect(audio.mutes["mic.input"] == true && audio.mutes["usb.input"] == true)
        // Switching the default input afterwards still leaves every microphone muted.
        audio.defaults[.input] = FakeAudioDevices.usbMicrophone
        #expect(!microphones.isLive(FakeAudioDevices.usbMicrophone))
        let unmuted = try microphones.toggle()
        #expect(unmuted.muted == false && unmuted.unchanged.isEmpty)
        #expect(audio.mutes["mic.input"] == false && audio.mutes["usb.input"] == false)
    }

    @Test func anyLiveInputMeansMuteRatherThanUnmute() throws {
        let audio = FakeAudioDevices()
        audio.inputs = [FakeAudioDevices.microphone, FakeAudioDevices.usbMicrophone]
        audio.mutes["mic.input"] = true
        let outcome = try MicrophoneMuteControl(audio: audio).toggle()
        #expect(outcome.muted)
        #expect(audio.mutes["mic.input"] == true && audio.mutes["usb.input"] == true)
    }

    @Test func gainFallbackSilencesEveryChannelAndRestoresEachMicrophonesOwnLevels() throws {
        let audio = FakeAudioDevices()
        audio.inputs = [FakeAudioDevices.microphone, FakeAudioDevices.usbMicrophone]
        audio.unmutable = ["usb.input"]
        audio.gains["usb.input"] = [1: 0.6, 2: 0.4]
        let microphones = MicrophoneMuteControl(audio: audio)
        #expect(try microphones.toggle().muted)
        #expect(audio.gains["usb.input"] == [1: 0, 2: 0])
        #expect(microphones.savedGains["usb"] == [1: 0.6, 2: 0.4])
        #expect(try !microphones.toggle().muted)
        #expect(audio.gains["usb.input"] == [1: 0.6, 2: 0.4])
        #expect(microphones.savedGains["usb"] == nil)
    }

    @Test func oneMicrophonesLevelNeverMovesToAnother() throws {
        let quiet = AudioDevice(id: 22, uid: "quiet", name: "Quiet Microphone", transport: .usb)
        let audio = FakeAudioDevices()
        audio.inputs = [FakeAudioDevices.usbMicrophone, quiet]
        audio.unmutable = ["usb.input", "quiet.input"]
        audio.gains["usb.input"] = [1: 0.8]
        audio.gains["quiet.input"] = [1: 0]
        let microphones = MicrophoneMuteControl(audio: audio)
        #expect(try microphones.toggle().muted)
        let outcome = try microphones.toggle()
        #expect(outcome == .init(muted: false, changed: ["USB Microphone"], unchanged: ["Quiet Microphone"]))
        #expect(audio.gains["usb.input"] == [1: 0.8])
        // The microphone that was already silent stays as it was.
        #expect(audio.gains["quiet.input"] == [1: 0])
    }

    @Test func inputsThatCantBeSilencedAreReportedNotHidden() throws {
        let audio = FakeAudioDevices()
        audio.inputs = [FakeAudioDevices.microphone, FakeAudioDevices.usbMicrophone]
        audio.unmutable = ["usb.input"]
        audio.gains["usb.input"] = [1: 0.5]
        audio.partialGain = ["usb.input"]
        let outcome = try MicrophoneMuteControl(audio: audio).toggle()
        #expect(outcome == .init(muted: true, changed: ["MacBook Microphone"], unchanged: ["USB Microphone"]))
        // Partial gain coverage isn't touched: zeroing some channels wouldn't silence it.
        #expect(audio.gains["usb.input"] == [1: 0.5])
    }

    @Test func aMuteThatDoesntTakeEffectIsNotReportedAsDone() {
        let audio = FakeAudioDevices()
        audio.ignoresChanges = ["mic.input"]
        #expect(throws: AudioDeviceError.noMuteControl) { try MicrophoneMuteControl(audio: audio).toggle() }
    }

    @Test func microphoneErrorsWithoutAnInput() {
        let audio = FakeAudioDevices()
        audio.inputs = []
        #expect(throws: AudioDeviceError.noDevice(.input)) { try MicrophoneMuteControl(audio: audio).toggle() }
    }

    // MARK: Devices

    @Test func devicesDescribeThemselves() {
        #expect(FakeAudioDevices.headphones.symbol(for: .output) == "headphones")
        #expect(FakeAudioDevices.speakers.symbol(for: .output) == "speaker.wave.2")
        #expect(FakeAudioDevices.microphone.symbol(for: .input) == "mic")
        #expect(AudioDevice(id: 1, uid: "tv", name: "TV", transport: .hdmi).symbol(for: .output) == "tv")
        #expect(AudioDevice(id: 1, uid: "air", name: "Air", transport: .airPlay).symbol(for: .output) == "airplayaudio")
        #expect(AudioScope.allCases.map(\.title) == ["Output", "Input"])
        #expect(AudioDeviceError.noDevice(.input).errorDescription == "No microphone is available.")
        #expect(AudioDeviceError.failed(-50).errorDescription?.contains("-50") == true)
    }

    @Test func switchingTheDefaultDeviceGoesThroughTheProtocol() throws {
        let audio = FakeAudioDevices()
        try audio.setDefaultDevice(FakeAudioDevices.headphones, for: .output)
        #expect(audio.defaultDevice(for: .output) == FakeAudioDevices.headphones)
        #expect(audio.devices(for: .output).count == 2)
        #expect(audio.devices(for: .input) == [FakeAudioDevices.microphone])
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func inertLaunchesGetNoSoundDevicesAndChangeNothing(_ mode: SideEffectGuard.Mode) {
        let sideEffects = SideEffectGuard(mode: mode)
        let audio = AudioDeviceEnvironment.makeDefault(sideEffects: sideEffects)
        #expect(audio is InertAudioDevices)
        #expect(audio.devices(for: .output).isEmpty && audio.defaultDevice(for: .input) == nil)
        #expect(throws: SideEffectGuard.Blocked.self) {
            try audio.setVolume(0.5, of: FakeAudioDevices.speakers, scope: .output)
        }
        // The Core Audio adapter refuses before touching a device. ID 0 is no device at all.
        let coreAudio = CoreAudioDevices(sideEffects: sideEffects)
        let nothing = AudioDevice(id: 0, uid: "none", name: "None", transport: .other)
        #expect(throws: SideEffectGuard.Blocked.self) { try coreAudio.setVolume(0.5, of: nothing, scope: .output) }
        #expect(throws: SideEffectGuard.Blocked.self) { try coreAudio.setMuted(true, of: nothing, scope: .input) }
        #expect(throws: SideEffectGuard.Blocked.self) { try coreAudio.setGain(0, of: nothing, scope: .input, element: 0) }
        #expect(throws: SideEffectGuard.Blocked.self) { try coreAudio.setDefaultDevice(nothing, for: .output) }
    }
}
