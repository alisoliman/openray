import AppKit
import Carbon
import Foundation
import Testing

@testable import OpenRay

/// A modifier event source that never observes the system: tests push inputs into it.
@MainActor
final class FakeModifierSource: ModifierEventSource {
    var handler: (@MainActor (ModifierInput) -> Void)?
    var delivers = true
    var startCount = 0
    var stopCount = 0

    func start(_ handler: @escaping @MainActor (ModifierInput) -> Void) -> Bool {
        startCount += 1
        self.handler = handler
        return delivers
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func send(_ input: ModifierInput) { handler?(input) }
}

/// A key backend that records Carbon registrations without making any.
final class SilentHotKeyBackend: GlobalHotKeyBackend {
    var active: [UInt32: CommandShortcut] = [:]
    func installHandler(_ action: @escaping (UInt32) -> Void) throws {}
    func register(_ shortcut: CommandShortcut, identifier: UInt32) throws { active[identifier] = shortcut }
    func unregister(identifier: UInt32) { active[identifier] = nil }
    func removeHandler() {}
}

@MainActor
final class FakeRemapper: KeyRemapping {
    var mappings: [KeyMapping] = []
    var writes = 0
    var fails = false
    func currentMappings() throws -> [KeyMapping] { mappings }
    func setMappings(_ mappings: [KeyMapping]) throws {
        if fails { throw LibraryValidationError("Refused.") }
        writes += 1
        self.mappings = mappings
    }
}

@MainActor
final class FakeHyperTap: HyperEventTap {
    var handler: (@MainActor (HyperKeyMachine.Input) -> HyperKeyMachine.Output)?
    var allowed = true
    func start(_ handler: @escaping @MainActor (HyperKeyMachine.Input) -> HyperKeyMachine.Output) -> Bool {
        guard allowed else { return false }
        self.handler = handler
        return true
    }
    func stop() { handler = nil }
}

@MainActor
final class FakeCapsLock: CapsLockToggling {
    var toggles = 0
    func toggle() { toggles += 1 }
}

@MainActor
struct HotKeyGestureTests {
    private let rightCommand = ModifierSides.rightCommand
    private let leftCommand = ModifierSides.leftCommand
    private let leftOption = ModifierSides.leftOption

    // MARK: Shortcut kinds

    @Test func gesturesFunctionKeysAndHyperChordsValidate() throws {
        try CommandShortcut.modifiersOnly([.option, .command]).validate()
        try CommandShortcut.modifiersOnly(.command, sides: .rightCommand).validate()
        try CommandShortcut.doubleTap(.command).validate()
        try CommandShortcut.doubleTap(.shift, side: .rightShift).validate()
        try CommandShortcut(keyCode: UInt32(kVK_F13), modifiers: []).validate()
        try CommandShortcut(keyCode: UInt32(kVK_F18), modifiers: []).validate()
        // The Hyper key's four modifiers with a key.
        try CommandShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: .all).validate()
        let refused = [
            CommandShortcut.modifiersOnly(.command),
            CommandShortcut.doubleTap([.command, .option]),
            CommandShortcut.modifiersOnly(.command, sides: [.leftCommand, .rightOption]),
            CommandShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: []),
            CommandShortcut(keyCode: UInt32(kVK_F5), modifiers: []),
            CommandShortcut(keyCode: 7, modifiers: .command, gesture: .modifiersOnly),
        ]
        for shortcut in refused { #expect(throws: LibraryValidationError.self) { try shortcut.validate() } }
    }

    @Test func gesturesShowTheirKeysAndKeepTheOldEncoding() throws {
        #expect(CommandShortcut.modifiersOnly([.option, .command]).caps == ["⌥", "⌘"])
        #expect(CommandShortcut.modifiersOnly(.command, sides: .rightCommand).caps == ["Right ⌘"])
        #expect(CommandShortcut.doubleTap(.command).caps == ["⌘", "⌘"])
        #expect(CommandShortcut(keyCode: UInt32(kVK_F13), modifiers: []).caps == ["F13"])
        #expect(!CommandShortcut.doubleTap(.command).isKeyChord)
        // A key shortcut encodes exactly as before: no new keys.
        let chord = CommandShortcut(keyCode: 8, modifiers: [.control, .option])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chord)) as? [String: Any])
        #expect(Set(object.keys) == ["keyCode", "modifiers"])
        let gesture = CommandShortcut.doubleTap(.command, side: .rightCommand)
        #expect(try JSONDecoder().decode(CommandShortcut.self, from: JSONEncoder().encode(gesture)) == gesture)
    }

    // MARK: Detection

    @Test func modifierOnlyGesturesFireOnReleaseWithoutAnotherKey() {
        var detector = ModifierGestureDetector(gestures: [
            "both": .modifiersOnly([.option, .command]),
            "right": .modifiersOnly(.command, sides: .rightCommand),
        ])
        #expect(detector.handle(.flags(leftOption, time: 0)).isEmpty)
        #expect(detector.handle(.flags([leftOption, leftCommand], time: 0.05)).isEmpty)
        #expect(detector.handle(.flags(leftCommand, time: 0.1)).isEmpty)
        #expect(detector.handle(.flags([], time: 0.15)) == ["both"])
        // With a key in between it was a shortcut, not a gesture.
        _ = detector.handle(.flags([leftOption, leftCommand], time: 1))
        _ = detector.handle(.key(time: 1.05))
        #expect(detector.handle(.flags([], time: 1.1)).isEmpty)
        // One side: right ⌘ fires; left ⌘ alone doesn't.
        _ = detector.handle(.flags(rightCommand, time: 2))
        #expect(detector.handle(.flags([], time: 2.1)) == ["right"])
        _ = detector.handle(.flags(leftCommand, time: 3))
        #expect(detector.handle(.flags([], time: 3.1)).isEmpty)
        // Held too long, it's a modifier being held, not a gesture.
        _ = detector.handle(.flags(rightCommand, time: 4))
        #expect(detector.handle(.flags([], time: 5.5)).isEmpty)
    }

    @Test func doubleTapsNeedTwoQuickCleanTapsOfOneModifier() {
        var detector = ModifierGestureDetector(gestures: ["double": .doubleTap(.command)])
        func tap(_ side: ModifierSides, at time: TimeInterval) -> [String] {
            _ = detector.handle(.flags(side, time: time))
            return detector.handle(.flags([], time: time + 0.05))
        }
        #expect(tap(leftCommand, at: 0).isEmpty)
        #expect(tap(leftCommand, at: 0.2) == ["double"])
        // Too slow.
        #expect(tap(leftCommand, at: 1).isEmpty)
        #expect(tap(leftCommand, at: 1.6).isEmpty)
        // A key between the taps.
        #expect(tap(leftCommand, at: 3).isEmpty)
        _ = detector.handle(.key(time: 3.1))
        #expect(tap(leftCommand, at: 3.15).isEmpty)
        // Different keys don't pair.
        #expect(tap(leftCommand, at: 5).isEmpty)
        #expect(tap(rightCommand, at: 5.2).isEmpty)
    }

    @Test func recordingTurnsModifierPressesIntoGestures() {
        var session = ShortcutRecordingSession()
        _ = session.handle(.flags([.leftOption, .rightCommand], time: 0))
        #expect(session.handle(.flags([], time: 0.1)) == .shortcut(.modifiersOnly([.option, .command])))
        _ = session.handle(.flags(.leftCommand, time: 1))
        #expect(session.handle(.flags([], time: 1.05)) == .pending)
        _ = session.handle(.flags(.leftCommand, time: 1.2))
        #expect(session.handle(.flags([], time: 1.25)) == .shortcut(.doubleTap(.command)))
        _ = session.handle(.flags(.rightShift, time: 2))
        #expect(session.handle(.flags([], time: 2.05)) == .pending)
        #expect(session.timeout() == .modifiersOnly(.shift, sides: .rightShift))
        #expect(session.timeout() == nil)
    }

    @Test func deviceFlagsMapToPhysicalKeys() {
        #expect(NSEventModifierSource.sides(fromDeviceFlags: 0x10) == .rightCommand)
        #expect(NSEventModifierSource.sides(fromDeviceFlags: 0x08 | 0x20) == [.leftCommand, .leftOption])
        #expect(NSEventModifierSource.sides(fromDeviceFlags: 0x2000 | 0x04) == [.rightControl, .rightShift])
    }

    // MARK: Registration

    @Test func gestureShortcutsRegisterBesideCarbonAndDispatch() {
        let source = FakeModifierSource()
        let backend = SilentHotKeyBackend()
        let registry = GlobalHotKey(
            backend: backend, reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: source))
        var launched = 0
        var commands: [String] = []
        let double = CommandShortcut.doubleTap(.command)
        let issues = registry.synchronize(
            launcherShortcut: double,
            bindings: [CommandBinding(targetID: "section.notes", shortcut: .modifiersOnly([.option, .command]))],
            onLauncher: { launched += 1 }, onCommand: { commands.append($0) })
        #expect(issues.isEmpty)
        // Nothing went to Carbon; the source is listening.
        #expect(backend.active.isEmpty)
        #expect(source.startCount == 1)
        for time in [0.0, 0.2] {
            source.send(.flags(.leftCommand, time: time))
            source.send(.flags([], time: time + 0.05))
        }
        #expect(launched == 1)
        source.send(.flags([.leftOption, .leftCommand], time: 2))
        source.send(.flags([], time: 2.1))
        #expect(commands == ["section.notes"])
        // Back to a key launcher: Carbon registers it and the source stops.
        _ = registry.synchronize(
            launcherShortcut: LauncherHotKey.optionSpace.shortcut, bindings: [], onLauncher: {}, onCommand: { _ in })
        #expect(backend.active.values.contains(LauncherHotKey.optionSpace.shortcut))
        #expect(source.stopCount == 1)
        registry.unregister()
    }

    @Test func gesturesWithoutAccessibilityAreReportedAndDuplicatesConflict() {
        let source = FakeModifierSource()
        source.delivers = false
        let registry = GlobalHotKey(
            backend: SilentHotKeyBackend(), reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: source))
        let gesture = CommandShortcut.modifiersOnly([.control, .option])
        let issues = registry.synchronize(
            launcherShortcut: LauncherHotKey.optionSpace.shortcut,
            bindings: [
                CommandBinding(targetID: "section.notes", shortcut: gesture),
                CommandBinding(targetID: "section.files", shortcut: gesture),
            ],
            onLauncher: {}, onCommand: { _ in })
        #expect(issues.contains { $0.targetID == "section.files" && $0.message.contains("inactive") })
        #expect(issues.contains { $0.targetID == "section.notes" && $0.message.contains("Accessibility") })
        registry.unregister()
    }

    @Test func theLauncherShortcutCanBeRecordedAndReset() {
        let source = FakeModifierSource()
        let backend = SilentHotKeyBackend()
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(),
            hotKey: GlobalHotKey(backend: backend, reservedShortcuts: { [] }, modifierHotKeys: ModifierHotKeys(source: source)))
        defer { model.stop() }
        model.isStarted = true
        model.synchronizeCommandHotKeys()
        // A preset is registered (which one depends on what this Mac reserves).
        #expect(!backend.active.isEmpty)
        // A modifier gesture opens OpenRay instead.
        #expect(model.setLauncherShortcut(.doubleTap(.command)))
        #expect(model.store.database.preferences.launcherHotKeyShortcut == .doubleTap(.command))
        #expect(backend.active.isEmpty)
        #expect(source.startCount == 1)
        // A shortcut a command uses is refused, and says so.
        let used = CommandShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option])
        #expect(model.store.saveCommandBinding(CommandBinding(targetID: "section.notes", shortcut: used)))
        #expect(!model.setLauncherShortcut(used))
        #expect(model.launcherHotKeyRefusal?.contains("Notes") == true)
        // Clearing it goes back to the preset, through Carbon again.
        #expect(model.setLauncherShortcut(nil))
        #expect(model.store.database.preferences.launcherShortcut == nil)
        #expect(backend.active.values.contains { $0 != used })
        #expect(source.stopCount == 1)
        // Choosing a preset replaces a recorded shortcut too.
        #expect(model.setLauncherShortcut(.modifiersOnly([.control, .option])))
        if model.setLauncherHotKey(.optionSpace) {
            #expect(model.store.database.preferences.launcherShortcut == nil)
        }
    }

    // MARK: Hyper key

    @Test func theHyperKeyHoldsItsModifiersAndKnowsALonePress() {
        var machine = HyperKeyMachine(modifiers: .all)
        #expect(machine.handle(.keyDown) == .passUnchanged)
        #expect(machine.handle(.hyperDown(isRepeat: false)) == .swallow)
        #expect(machine.handle(.hyperDown(isRepeat: true)) == .swallow)
        #expect(machine.handle(.keyDown) == .addModifiers(.all))
        #expect(machine.handle(.keyUp) == .addModifiers(.all))
        #expect(machine.handle(.hyperUp) == .swallow)
        #expect(machine.handle(.keyDown) == .passUnchanged)
        // Pressed and released alone.
        #expect(machine.handle(.hyperDown(isRepeat: false)) == .swallow)
        #expect(machine.handle(.hyperUp) == .quickPress)
        machine.modifiers = [.command, .control, .option]
        _ = machine.handle(.hyperDown(isRepeat: false))
        #expect(machine.handle(.keyDown) == .addModifiers([.command, .control, .option]))
    }

    @Test func theRemapKeepsOtherMappingsAndReadsHidutilOutput() {
        let other = KeyMapping(source: 0x7_0000_00E0, destination: 0x7_0000_00E3)
        #expect(HyperRemapPlan.adding(to: [other]) == [other, .capsLockToF18])
        #expect(HyperRemapPlan.adding(to: [.capsLockToF18]) == [.capsLockToF18])
        #expect(HyperRemapPlan.removing(from: [other, .capsLockToF18]) == [other])
        let output = """
            (
                    {
                    HIDKeyboardModifierMappingDst = 30064771181;
                    HIDKeyboardModifierMappingSrc = 30064771129;
                },
                    {
                    HIDKeyboardModifierMappingDst = 30064771299;
                    HIDKeyboardModifierMappingSrc = 30064771296;
                }
            )
            """
        #expect(HyperRemapPlan.parse(output) == [.capsLockToF18, other])
        #expect(HyperRemapPlan.parse("(null)").isEmpty)
        #expect(
            HyperRemapPlan.json([.capsLockToF18])
                == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#)
    }

    @Test func turningTheHyperKeyOnAndOffRemapsAndRestores() {
        let remapper = FakeRemapper()
        let other = KeyMapping(source: 0x7_0000_00E0, destination: 0x7_0000_00E3)
        remapper.mappings = [other]
        let tap = FakeHyperTap()
        let capsLock = FakeCapsLock()
        let hyper = HyperKey(remapper: remapper, tap: tap, capsLock: capsLock)
        var settings = HyperKeySettings()
        // Off by default: nothing is touched.
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(remapper.writes == 0)
        settings.isEnabled = true
        // Without Accessibility it says why and touches nothing.
        hyper.apply(settings, accessibilityAllowed: false)
        #expect(remapper.writes == 0)
        #expect(hyper.problem?.contains("Accessibility") == true)
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(hyper.isActive)
        #expect(remapper.mappings == [other, .capsLockToF18])
        #expect(hyper.problem == nil)
        // A lone press toggles Caps Lock, as chosen.
        _ = tap.handler?(.hyperDown(isRepeat: false))
        #expect(tap.handler?(.hyperUp) == .quickPress)
        #expect(capsLock.toggles == 1)
        settings.quickPress = .nothing
        hyper.apply(settings, accessibilityAllowed: true)
        _ = tap.handler?(.hyperDown(isRepeat: false))
        _ = tap.handler?(.hyperUp)
        #expect(capsLock.toggles == 1)
        // Off again: the tap stops and only OpenRay's mapping goes.
        settings.isEnabled = false
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(!hyper.isActive)
        #expect(tap.handler == nil)
        #expect(remapper.mappings == [other])
    }

    @Test func aRefusedTapUndoesTheRemapAndAStaleRemapIsRemoved() {
        let remapper = FakeRemapper()
        let tap = FakeHyperTap()
        tap.allowed = false
        let hyper = HyperKey(remapper: remapper, tap: tap, capsLock: FakeCapsLock())
        var settings = HyperKeySettings()
        settings.isEnabled = true
        hyper.apply(settings, accessibilityAllowed: true)
        #expect(!hyper.isActive)
        #expect(remapper.mappings.isEmpty)
        #expect(hyper.problem != nil)
        // A remap a crash left behind goes at the next launch while the Hyper key is off.
        remapper.mappings = [.capsLockToF18]
        hyper.removeStaleRemap(HyperKeySettings())
        #expect(remapper.mappings.isEmpty)
    }
}
