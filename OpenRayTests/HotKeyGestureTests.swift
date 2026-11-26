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

/// A Hyper event tap that never touches the system: tests read the mapping it was given.
@MainActor
final class FakeHyperTap: HyperEventTap {
    var map: (@Sendable (UInt64) -> UInt64)?
    var allowed = true
    var starts = 0
    var isRunning: Bool { map != nil }
    func start(map: @escaping @Sendable (UInt64) -> UInt64) -> Bool {
        guard allowed else { return false }
        starts += 1
        self.map = map
        return true
    }
    func stop() { map = nil }
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

    /// Flags as a key event carries them: device bits per physical key, plus the generic modifier.
    private let rightCommandDown: UInt64 = 0x10 | CGEventFlags.maskCommand.rawValue
    private let leftCommandDown: UInt64 = 0x08 | CGEventFlags.maskCommand.rawValue
    private let hyperFlags: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue

    @Test func theHyperMappingAddsModifiersOnlyWhileTheKeyIsPhysicallyDown() {
        let map = { (flags: UInt64) in HyperKeyMapping.flags(flags, trigger: .rightCommand, modifiers: .all) }
        // Held: every Hyper modifier is added.
        #expect(map(rightCommandDown) & hyperFlags == hyperFlags)
        // The left key is a plain ⌘.
        #expect(map(leftCommandDown) == leftCommandDown)
        // Released, or a release that was never seen: the event's own flags say the key is up.
        #expect(map(0) == 0)
        #expect(map(CGEventFlags.maskShift.rawValue) == CGEventFlags.maskShift.rawValue)
        // Inconsistent flags (the device bit without its modifier) pass unchanged.
        #expect(map(0x10) == 0x10)
        // Without Shift, Shift isn't added.
        let noShift = HyperKeyMapping.flags(rightCommandDown, trigger: .rightCommand, modifiers: [.command, .control, .option])
        #expect(noShift & CGEventFlags.maskShift.rawValue == 0)
        // Other keys: Right ⌥.
        let rightOption: UInt64 = 0x40 | CGEventFlags.maskAlternate.rawValue
        #expect(HyperKeyMapping.flags(rightOption, trigger: .rightOption, modifiers: .all) & hyperFlags == hyperFlags)
        #expect(HyperKeyMapping.flags(rightOption, trigger: .rightCommand, modifiers: .all) == rightOption)
    }

    @Test func aLostReleaseNeverOutlivesTheKey() {
        // The mapping holds no state: whatever happened before, a key event with the key up passes unchanged.
        let tap = FakeHyperTap()
        let hyper = HyperKey(tap: tap)
        hyper.apply(HyperKeySettings(isEnabled: true), accessibilityAllowed: true)
        guard let map = tap.map else {
            Issue.record("The tap didn't start")
            return
        }
        #expect(map(rightCommandDown) != rightCommandDown)
        // A key-up for the Hyper key went missing; the next keys show it's up.
        for _ in 0..<3 { #expect(map(0) == 0) }
        #expect(map(CGEventFlags.maskAlternate.rawValue) == CGEventFlags.maskAlternate.rawValue)
    }

    @Test func turningTheHyperKeyOnAndOffOnlyStartsAndStopsTheTap() {
        let tap = FakeHyperTap()
        let hyper = HyperKey(tap: tap)
        // Off by default: nothing starts.
        hyper.apply(HyperKeySettings(), accessibilityAllowed: true)
        #expect(tap.starts == 0)
        // Without Accessibility it says why and starts nothing.
        hyper.apply(HyperKeySettings(isEnabled: true), accessibilityAllowed: false)
        #expect(tap.starts == 0)
        #expect(hyper.problem?.contains("Accessibility") == true)
        hyper.apply(HyperKeySettings(isEnabled: true), accessibilityAllowed: true)
        #expect(hyper.isActive)
        #expect(hyper.problem == nil)
        // The same settings again don't restart it; a new key does.
        hyper.apply(HyperKeySettings(isEnabled: true), accessibilityAllowed: true)
        #expect(tap.starts == 1)
        hyper.apply(HyperKeySettings(isEnabled: true, trigger: .rightOption), accessibilityAllowed: true)
        #expect(tap.starts == 2)
        // Off: the tap stops, and nothing outlasts it.
        hyper.apply(HyperKeySettings(), accessibilityAllowed: true)
        #expect(!hyper.isActive)
        #expect(tap.map == nil)
        // A refused tap reports it.
        tap.allowed = false
        hyper.apply(HyperKeySettings(isEnabled: true), accessibilityAllowed: true)
        #expect(!hyper.isActive)
        #expect(hyper.problem != nil)
    }

    @Test func hyperSettingsDecodeWhateverAnotherBuildSaved() throws {
        let partial = try JSONDecoder().decode(HyperKeySettings.self, from: Data(#"{"isEnabled":true}"#.utf8))
        #expect(partial == HyperKeySettings(isEnabled: true))
        let unknownKey = try JSONDecoder().decode(
            HyperKeySettings.self, from: Data(#"{"isEnabled":true,"trigger":"capsLock","quickPress":"x"}"#.utf8))
        #expect(unknownKey.trigger == .rightCommand)
    }

    // MARK: Live adapters stay inert here

    @Test func liveKeyboardAdaptersAreInertInTheTestHost() throws {
        #expect(SideEffectGuard.isInert)
        // The real event tap and modifier monitors refuse to start.
        let tap = CGHyperEventTap()
        let started = tap.start(map: { $0 })
        #expect(!started)
        #expect(!tap.isRunning)
        #expect(!NSEventModifierSource().start { _ in })
        // Carbon refuses to register a global shortcut.
        #expect(throws: SideEffectGuard.Blocked.self) {
            try CarbonHotKeyBackend().register(LauncherHotKey.optionSpace.shortcut, identifier: 1)
        }
        // The shortcut recorder watches nothing.
        #expect(CommandShortcutCaptureView().monitoring is InertLocalEventMonitoring)
        // A model handed the system clipboard and a real hotkey registry still stays inert: its
        // clipboard is a private one, so a copy never reaches the system clipboard.
        let model = LauncherModel(store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: .general)
        defer { model.stop() }
        model.isStarted = true
        model.synchronizeCommandHotKeys()
        #expect(model.hotKey.modifierHotKeys.registeredIDs.isEmpty)
        #expect(!model.clipboard.usesGeneralPasteboard)
        let systemChangeCount = NSPasteboard.general.changeCount
        model.copy("never written to the system clipboard")
        #expect(NSPasteboard.general.changeCount == systemChangeCount)
    }

    /// Partials 1 and 2: a guard injected as live can't switch the live adapters on in this
    /// inert process; each one checks the process's own rule at its boundary.
    @Test func anInjectedLiveGuardCantStartLiveAdaptersInTheTestHost() throws {
        let live = SideEffectGuard(mode: .live)
        let tap = CGHyperEventTap(sideEffects: live)
        let started = tap.start(map: { $0 })
        #expect(!started)
        #expect(!tap.isRunning)
        #expect(!NSEventModifierSource(sideEffects: live).start { _ in })
        #expect(live.localEventMonitoring is InertLocalEventMonitoring)
        let installed = AppKitLocalEventMonitoring().add([.keyDown]) { $0 }
        #expect(installed == nil)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: .withUniqueName(),
            sideEffects: live)
        defer { model.stop() }
        #expect(model.sideEffects.isInert)
    }
}
