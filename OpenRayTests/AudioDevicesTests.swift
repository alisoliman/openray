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

    @Test func microphoneMuteUsesTheMuteControlWhenThereIsOne() throws {
        let audio = FakeAudioDevices()
        audio.unmutable = []
        let microphone = MicrophoneMuteControl(audio: audio)
        #expect(try microphone.toggle())
        #expect(try !microphone.toggle())
        #expect(audio.changes == ["mute.mic.input=true", "mute.mic.input=false"])
        #expect(audio.volumes["mic.input"] == 0.6)
    }

    @Test func microphoneWithoutAMuteControlIsMutedByVolumeAndRestored() throws {
        let audio = FakeAudioDevices()
        let microphone = MicrophoneMuteControl(audio: audio)
        #expect(try microphone.toggle())
        #expect(audio.volumes["mic.input"] == 0)
        #expect(microphone.restoreVolume == 0.6)
        #expect(try !microphone.toggle())
        #expect(audio.volumes["mic.input"] == 0.6)
        #expect(microphone.restoreVolume == nil)
        // Already at zero with nothing remembered: back to a usable level.
        audio.volumes["mic.input"] = 0
        #expect(try !microphone.toggle())
        #expect(audio.volumes["mic.input"] == MicrophoneMuteControl.fallbackVolume)
    }

    @Test func microphoneErrorsWithoutAnInputOrAnyControl() {
        let audio = FakeAudioDevices()
        audio.volumeless = ["mic.input"]
        #expect(throws: AudioDeviceError.noMuteControl) { try MicrophoneMuteControl(audio: audio).toggle() }
        audio.defaults[.input] = nil
        #expect(throws: AudioDeviceError.noDevice(.input)) { try MicrophoneMuteControl(audio: audio).toggle() }
    }

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
}
