import Carbon
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct GlobalHotKeyTests {
    private let clipboard = "section.clipboard"
    private let notes = "section.notes"
    private let shortcut = CommandShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: [.control, .option])
    private let otherShortcut = CommandShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option])

    @Test func standardShortcutRoundTripsAndPreservesLauncherPreferences() throws {
        try shortcut.validate()
        #expect(try JSONDecoder().decode(CommandShortcut.self, from: JSONEncoder().encode(shortcut)) == shortcut)
        #expect(shortcut.modifiers.carbonFlags == UInt32(controlKey | optionKey))
        #expect(ShortcutModifiers(carbonFlags: UInt32(controlKey | optionKey)) == shortcut.modifiers)
        #expect(LauncherHotKey.optionSpace.shortcut == .init(keyCode: UInt32(kVK_Space), modifiers: .option))
        #expect(LauncherHotKey.controlSpace.shortcut.modifiers == .control)
        #expect(LauncherHotKey.controlOptionSpace.shortcut.modifiers == [.control, .option])
        #expect(LauncherHotKey.optionSpace.shortcut.title == "⌥ Space")
    }

    @Test func unsupportedGesturesAreRejected() {
        let invalid = [
            CommandShortcut(keyCode: 8, modifiers: []),
            CommandShortcut(keyCode: 8, modifiers: .all),
            CommandShortcut(keyCode: 8, modifiers: .init(rawValue: 1 << 8)),
            CommandShortcut(keyCode: UInt32(kVK_Command), modifiers: .command),
            CommandShortcut(keyCode: UInt32(kVK_RightCommand), modifiers: .command),
            CommandShortcut(keyCode: UInt32(kVK_Function), modifiers: .control),
            CommandShortcut(keyCode: UInt32.max, modifiers: .control),
        ]
        for candidate in invalid { #expect(throws: LibraryValidationError.self) { try candidate.validate() } }
    }

    @Test func systemReservedShortcutsBlockWhileAppConflictsOnlyWarn() throws {
        for candidate in CommandShortcutPolicy.fixedReservedShortcuts {
            #expect(throws: LibraryValidationError.self) { try candidate.validate() }
        }
        let copy = CommandShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: .command)
        try copy.validate()
        #expect(!CommandShortcutPolicy.conflictWarnings(for: copy).isEmpty)
        for modifiers: ShortcutModifiers in [.shift, .option, [.shift, .option]] {
            let typing = CommandShortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: modifiers)
            try typing.validate()
            #expect(!CommandShortcutPolicy.conflictWarnings(for: typing).isEmpty)
        }
        #expect(CommandShortcutPolicy.conflictWarnings(for: shortcut).isEmpty)
        #expect(throws: LibraryValidationError.self) {
            try CommandShortcutPolicy.validate(shortcut: shortcut, reservedShortcuts: [shortcut])
        }
        try CommandShortcutPolicy.validate(shortcut: shortcut, reservedShortcuts: [])
    }

    @Test func routesEachEventToOneTargetAndUpdatesClosuresWithoutReregistering() throws {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        let bindings = [
            CommandBinding(targetID: clipboard, shortcut: shortcut),
            CommandBinding(targetID: notes, shortcut: otherShortcut),
        ]
        var launcherCount = 0
        var targets: [String] = []
        #expect(
            registry.synchronize(
                launcher: .optionSpace, bindings: bindings, onLauncher: { launcherCount += 1 },
                onCommand: { targets.append($0) }
            ).isEmpty)
        #expect(backend.active.count == 3)
        let launcherID = try #require(backend.identifier(for: LauncherHotKey.optionSpace.shortcut))
        let commandID = try #require(backend.identifier(for: shortcut))
        backend.fire(launcherID)
        #expect(launcherCount == 1)
        #expect(targets.isEmpty)
        backend.fire(commandID)
        #expect(launcherCount == 1)
        #expect(targets == [clipboard])
        let active = backend.active
        _ = registry.synchronize(
            launcher: .optionSpace, bindings: bindings, onLauncher: { launcherCount += 10 },
            onCommand: { targets.append("updated:" + $0) })
        #expect(backend.active == active)
        #expect(backend.registrationAttempts.count == 3)
        #expect(backend.installCount == 1)
        backend.fire(launcherID)
        backend.fire(commandID)
        backend.fire(UInt32.max)
        #expect(launcherCount == 11)
        #expect(targets == [clipboard, "updated:" + clipboard])
        registry.unregister()
        #expect(backend.active.isEmpty)
        #expect(backend.removeHandlerCount == 1)
    }

    @Test func removingACommandUnregistersItAndDropsQueuedEvents() throws {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        var targets: [String] = []
        _ = registry.synchronize(
            launcher: .optionSpace, bindings: [.init(targetID: clipboard, shortcut: shortcut)], onLauncher: {},
            onCommand: { targets.append($0) })
        let removedID = try #require(backend.identifier(for: shortcut))
        _ = registry.synchronize(
            launcher: .optionSpace, bindings: [], onLauncher: {}, onCommand: { targets.append($0) })
        backend.fire(removedID)
        #expect(targets.isEmpty)
        #expect(backend.unregisteredIDs == [removedID])
        #expect(backend.active.count == 1)
        registry.unregister()
        registry.unregister()
        #expect(backend.removeHandlerCount == 1)
    }

    @Test func failedLauncherReplacementKeepsWorkingLauncherAndOtherCommands() throws {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        var launcherCount = 0
        _ = registry.synchronize(
            launcher: .optionSpace, bindings: [], onLauncher: { launcherCount += 1 }, onCommand: { _ in })
        let originalID = try #require(backend.identifier(for: LauncherHotKey.optionSpace.shortcut))
        backend.failures = [LauncherHotKey.controlSpace.shortcut]
        let issues = registry.synchronize(
            launcher: .controlSpace, bindings: [.init(targetID: clipboard, shortcut: shortcut)],
            onLauncher: { launcherCount += 1 }, onCommand: { _ in })
        #expect(issues.map(\.targetID) == [GlobalHotKey.launcherTargetID])
        #expect(issues.first?.message.contains("⌥ Space remains active") == true)
        #expect(backend.identifier(for: LauncherHotKey.optionSpace.shortcut) == originalID)
        #expect(!backend.unregisteredIDs.contains(originalID))
        #expect(backend.identifier(for: shortcut) != nil)
        backend.fire(originalID)
        #expect(launcherCount == 1)
        backend.failures = []
        #expect(
            registry.synchronize(launcher: .controlSpace, bindings: [], onLauncher: {}, onCommand: { _ in }).isEmpty)
        #expect(backend.identifier(for: LauncherHotKey.optionSpace.shortcut) == nil)
        #expect(backend.identifier(for: LauncherHotKey.controlSpace.shortcut) != nil)
        #expect(backend.unregisteredIDs.filter { $0 == originalID }.count == 1)
        registry.unregister()
    }

    @Test func launcherTakesPriorityOverAnExistingCommandAssignment() throws {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        let bindings = [CommandBinding(targetID: clipboard, shortcut: LauncherHotKey.controlSpace.shortcut)]
        var launcherCount = 0
        var targets: [String] = []
        _ = registry.synchronize(launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
        let oldCommandID = try #require(backend.identifier(for: LauncherHotKey.controlSpace.shortcut))
        let issues = registry.synchronize(
            launcher: .controlSpace, bindings: bindings, onLauncher: { launcherCount += 1 },
            onCommand: { targets.append($0) })
        let launcherID = try #require(backend.identifier(for: LauncherHotKey.controlSpace.shortcut))
        #expect(launcherID != oldCommandID)
        #expect(issues.map(\.targetID) == [clipboard])
        backend.fire(oldCommandID)
        backend.fire(launcherID)
        #expect(launcherCount == 1)
        #expect(targets.isEmpty)
        #expect(backend.active.count == 1)
        registry.unregister()
    }

    @Test func duplicateCommandsUseTheFirstBindingAndCanChangeOwnership() throws {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        let bindings = [
            CommandBinding(targetID: clipboard, shortcut: shortcut),
            CommandBinding(targetID: notes, shortcut: shortcut),
        ]
        var targets: [String] = []
        let issues = registry.synchronize(
            launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { targets.append($0) })
        #expect(issues.map(\.targetID) == [notes])
        backend.fire(try #require(backend.identifier(for: shortcut)))
        #expect(targets == [clipboard])
        let reversedIssues = registry.synchronize(
            launcher: .optionSpace, bindings: bindings.reversed(), onLauncher: {}, onCommand: { targets.append($0) })
        #expect(reversedIssues.map(\.targetID) == [clipboard])
        backend.fire(try #require(backend.identifier(for: shortcut)))
        #expect(targets == [clipboard, notes])
        #expect(backend.active.count == 2)
        registry.unregister()
    }

    @Test func oneRegistrationFailureDoesNotPreventOtherCommandsAndRetriesLater() {
        let backend = FakeHotKeyBackend()
        backend.failures = [shortcut]
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        let bindings = [
            CommandBinding(targetID: clipboard, shortcut: shortcut),
            CommandBinding(targetID: notes, shortcut: otherShortcut),
        ]
        let issues = registry.synchronize(
            launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
        #expect(issues.map(\.targetID) == [clipboard])
        #expect(issues.first?.message.contains("saved but inactive") == true)
        #expect(backend.identifier(for: otherShortcut) != nil)
        #expect(backend.identifier(for: LauncherHotKey.optionSpace.shortcut) != nil)
        backend.failures = []
        #expect(
            registry.synchronize(launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
                .isEmpty)
        #expect(backend.active.count == 3)
        registry.unregister()
    }

    @Test func handlerFailureIsReportedForAllTargetsAndCanBeRetried() {
        let backend = FakeHotKeyBackend()
        backend.installFails = true
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        let bindings = [CommandBinding(targetID: clipboard, shortcut: shortcut)]
        let issues = registry.synchronize(
            launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
        #expect(issues.map(\.targetID) == [GlobalHotKey.launcherTargetID, clipboard])
        #expect(backend.active.isEmpty)
        backend.installFails = false
        #expect(
            registry.synchronize(launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
                .isEmpty)
        #expect(backend.active.count == 2)
        registry.unregister()
    }

    @Test func newlyEnabledSystemShortcutRemovesAnExistingRegistration() {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { backend.reservedShortcuts })
        let bindings = [CommandBinding(targetID: clipboard, shortcut: shortcut)]
        _ = registry.synchronize(launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
        backend.reservedShortcuts = [shortcut]
        let issues = registry.synchronize(
            launcher: .optionSpace, bindings: bindings, onLauncher: {}, onCommand: { _ in })
        #expect(issues.map(\.targetID) == [clipboard])
        #expect(backend.identifier(for: shortcut) == nil)
        #expect(backend.active.count == 1)
        registry.unregister()
    }

    @Test func swappingCommandShortcutsReleasesOldRegistrationsBeforeInstallingNewOnes() {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        _ = registry.synchronize(
            launcher: .optionSpace,
            bindings: [
                .init(targetID: clipboard, shortcut: shortcut), .init(targetID: notes, shortcut: otherShortcut),
            ],
            onLauncher: {}, onCommand: { _ in })
        let issues = registry.synchronize(
            launcher: .optionSpace,
            bindings: [
                .init(targetID: clipboard, shortcut: otherShortcut), .init(targetID: notes, shortcut: shortcut),
            ],
            onLauncher: {}, onCommand: { _ in })
        #expect(issues.isEmpty)
        #expect(backend.active.count == 3)
        registry.unregister()
    }

    @Test func unsupportedTargetsAreNeverRegistered() {
        let backend = FakeHotKeyBackend()
        let registry = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        let issues = registry.synchronize(
            launcher: .optionSpace, bindings: [.init(targetID: "snippet.deleted", shortcut: shortcut)],
            onLauncher: {}, onCommand: { _ in })
        #expect(issues.map(\.targetID) == ["snippet.deleted"])
        #expect(backend.identifier(for: shortcut) == nil)
        #expect(backend.active.count == 1)
        registry.unregister()
    }

    @Test func releasingRegistryRemovesAllRegistrationsAndTheHandler() {
        let backend = FakeHotKeyBackend()
        var registry: GlobalHotKey? = GlobalHotKey(backend: backend, reservedShortcuts: { [] })
        _ = registry?.synchronize(
            launcher: .optionSpace, bindings: [.init(targetID: clipboard, shortcut: shortcut)],
            onLauncher: {}, onCommand: { _ in })
        #expect(backend.active.count == 2)
        registry = nil
        #expect(backend.active.isEmpty)
        #expect(backend.removeHandlerCount == 1)
    }

    @Test func inProcessCarbonEventDispatchExtractsIdentifierAndIgnoresForeignSignatures() throws {
        // Exercise the production Carbon handler without registering a system hotkey or
        // synthesizing a keyboard gesture. Events stay inside this application's event target.
        let backend = CarbonHotKeyBackend()
        var identifiers: [UInt32] = []
        try backend.installHandler { identifiers.append($0) }
        defer { backend.removeHandler() }

        func send(signature: OSType, identifier: UInt32) throws -> OSStatus {
            var event: EventRef?
            let creationStatus = CreateEvent(
                nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                OptionBits(kEventAttributeUserEvent), &event)
            #expect(creationStatus == noErr)
            let createdEvent = try #require(event)
            defer { ReleaseEvent(createdEvent) }
            var hotKeyID = EventHotKeyID(signature: signature, id: identifier)
            let parameterStatus = SetEventParameter(
                createdEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &hotKeyID)
            #expect(parameterStatus == noErr)
            return SendEventToEventTarget(createdEvent, GetApplicationEventTarget())
        }

        #expect(try send(signature: 0x4F52_4159, identifier: 7_001) == noErr)
        #expect(identifiers == [7_001])
        _ = try send(signature: 0x5445_5354, identifier: 7_002)
        #expect(identifiers == [7_001])
        #expect(try send(signature: 0x4F52_4159, identifier: 7_003) == noErr)
        #expect(identifiers == [7_001, 7_003])
        backend.removeHandler()
        _ = try send(signature: 0x4F52_4159, identifier: 7_004)
        #expect(identifiers == [7_001, 7_003])
    }

    @Test func carbonRegistrationRequestsExclusiveOwnershipAndReportsConflicts() {
        var attempts = 0
        let backend = CarbonHotKeyBackend { keyCode, modifiers, identifier, options, reference in
            attempts += 1
            #expect(keyCode == shortcut.keyCode)
            #expect(modifiers == shortcut.modifiers.carbonFlags)
            #expect(identifier.id == 73)
            #expect(identifier.signature == 0x4F52_4159)
            #expect(options == OptionBits(kEventHotKeyExclusive))
            #expect(reference == nil)
            return OSStatus(eventHotKeyExistsErr)
        }

        do {
            try backend.register(shortcut, identifier: 73)
            Issue.record("A shortcut already owned by another app must remain inactive.")
        } catch {
            #expect(error is LibraryValidationError)
            #expect(error.localizedDescription.contains(shortcut.title))
            #expect(error.localizedDescription.contains("another app may use it"))
            #expect(error.localizedDescription.contains(String(eventHotKeyExistsErr)))
        }
        #expect(attempts == 1)
    }
}

@MainActor
private final class FakeHotKeyBackend: GlobalHotKeyBackend {
    var active: [UInt32: CommandShortcut] = [:]
    var registrationAttempts: [UInt32] = []
    var unregisteredIDs: [UInt32] = []
    var failures: Set<CommandShortcut> = []
    var reservedShortcuts: Set<CommandShortcut> = []
    var installFails = false
    var installCount = 0
    var removeHandlerCount = 0
    private var action: ((UInt32) -> Void)?

    func installHandler(_ action: @escaping (UInt32) -> Void) throws {
        installCount += 1
        guard !installFails else { throw LibraryValidationError("Simulated handler failure.") }
        self.action = action
    }

    func register(_ shortcut: CommandShortcut, identifier: UInt32) throws {
        registrationAttempts.append(identifier)
        guard !failures.contains(shortcut), !active.values.contains(shortcut) else {
            throw LibraryValidationError("Simulated registration failure.")
        }
        active[identifier] = shortcut
    }

    func unregister(identifier: UInt32) {
        unregisteredIDs.append(identifier)
        active.removeValue(forKey: identifier)
    }

    func removeHandler() {
        removeHandlerCount += 1
        action = nil
    }

    func identifier(for shortcut: CommandShortcut) -> UInt32? {
        active.first { $0.value == shortcut }?.key
    }

    func fire(_ identifier: UInt32) { action?(identifier) }
}
