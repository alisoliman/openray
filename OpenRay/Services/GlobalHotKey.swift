import Carbon
import Foundation

struct HotKeyRegistrationIssue: Equatable, Sendable {
    var targetID: String
    var message: String
}

@MainActor
protocol GlobalHotKeyBackend: AnyObject {
    func installHandler(_ action: @escaping (UInt32) -> Void) throws
    func register(_ shortcut: CommandShortcut, identifier: UInt32) throws
    func unregister(identifier: UInt32)
    func removeHandler()
}

@MainActor
final class GlobalHotKey {
    static let launcherTargetID = "openray.launcher"

    private struct Registration {
        var shortcut: CommandShortcut
        var identifier: UInt32
    }

    private let backend: any GlobalHotKeyBackend
    private let reservedShortcuts: @MainActor () -> Set<CommandShortcut>
    private var registrations: [String: Registration] = [:]
    private var nextIdentifier: UInt32 = 1
    private var handlerInstalled = false
    private var onLauncher: (() -> Void)?
    private var onCommand: ((String) -> Void)?

    init(
        backend: any GlobalHotKeyBackend = CarbonHotKeyBackend(),
        reservedShortcuts: @escaping @MainActor () -> Set<CommandShortcut> = CommandShortcutPolicy
            .systemReservedShortcuts
    ) {
        self.backend = backend
        self.reservedShortcuts = reservedShortcuts
    }

    isolated deinit { unregister() }

    func synchronize(
        launcher: LauncherHotKey, bindings: [CommandBinding],
        onLauncher: @escaping () -> Void, onCommand: @escaping (String) -> Void
    ) -> [HotKeyRegistrationIssue] {
        self.onLauncher = onLauncher
        self.onCommand = onCommand
        let reserved = reservedShortcuts()
        var issues: [HotKeyRegistrationIssue] = []
        var desired: [(String, CommandShortcut)] = []
        var owners: [CommandShortcut: String] = [:]
        let candidates =
            [(Self.launcherTargetID, launcher.shortcut)]
            + bindings.compactMap { binding in
                binding.shortcut.map { (binding.targetID, $0) }
            }
        for (targetID, shortcut) in candidates {
            guard targetID == Self.launcherTargetID || CuratedCommand.supports(targetID) else {
                issues.append(.init(targetID: targetID, message: "This command does not support a global hotkey."))
                continue
            }
            do { try CommandShortcutPolicy.validate(shortcut: shortcut, reservedShortcuts: reserved) } catch {
                issues.append(.init(targetID: targetID, message: error.localizedDescription))
                continue
            }
            if let owner = owners[shortcut] {
                let ownerTitle = owner == Self.launcherTargetID ? "the launcher" : "another command (\(owner))"
                issues.append(
                    .init(targetID: targetID, message: "\(shortcut.title) is inactive because \(ownerTitle) uses it."))
                continue
            }
            owners[shortcut] = targetID
            desired.append((targetID, shortcut))
        }

        // Remove stale command registrations before new ones, allowing swaps and launcher priority.
        // Keep the old launcher until its replacement succeeds, unless macOS now reserves it.
        for (targetID, registration) in registrations {
            if targetID == Self.launcherTargetID {
                if (try? CommandShortcutPolicy.validate(shortcut: registration.shortcut, reservedShortcuts: reserved))
                    == nil
                {
                    remove(targetID)
                }
            } else if !desired.contains(where: { $0.0 == targetID && $0.1 == registration.shortcut }) {
                remove(targetID)
            }
        }

        if !handlerInstalled, !desired.isEmpty {
            do {
                try backend.installHandler { [weak self] identifier in self?.dispatch(identifier) }
                handlerInstalled = true
            } catch {
                issues += desired.map { .init(targetID: $0.0, message: error.localizedDescription) }
                return issues
            }
        }

        for (targetID, shortcut) in desired {
            if registrations[targetID]?.shortcut == shortcut { continue }
            if registrations.contains(where: { $0.key != targetID && $0.value.shortcut == shortcut }) {
                issues.append(
                    .init(
                        targetID: targetID,
                        message: "\(shortcut.title) is inactive because the previous launcher shortcut is still active."
                    ))
                continue
            }
            let identifier = nextIdentifier
            nextIdentifier += 1
            do {
                try backend.register(shortcut, identifier: identifier)
                remove(targetID)
                registrations[targetID] = Registration(shortcut: shortcut, identifier: identifier)
            } catch {
                let fallback =
                    registrations[targetID].map { " \($0.shortcut.title) remains active." }
                    ?? " The shortcut is saved but inactive."
                issues.append(.init(targetID: targetID, message: error.localizedDescription + fallback))
            }
        }
        if !desired.contains(where: { $0.0 == Self.launcherTargetID }),
            let previous = registrations[Self.launcherTargetID]
        {
            if let index = issues.firstIndex(where: { $0.targetID == Self.launcherTargetID }) {
                issues[index].message += " \(previous.shortcut.title) remains active."
            }
        }
        return issues
    }

    func unregister() {
        for registration in registrations.values { backend.unregister(identifier: registration.identifier) }
        registrations.removeAll()
        if handlerInstalled { backend.removeHandler() }
        handlerInstalled = false
        onLauncher = nil
        onCommand = nil
    }

    private func remove(_ targetID: String) {
        if let registration = registrations.removeValue(forKey: targetID) {
            backend.unregister(identifier: registration.identifier)
        }
    }

    private func dispatch(_ identifier: UInt32) {
        guard let targetID = registrations.first(where: { $0.value.identifier == identifier })?.key else { return }
        if targetID == Self.launcherTargetID { onLauncher?() } else { onCommand?(targetID) }
    }
}

@MainActor
final class CarbonHotKeyBackend: GlobalHotKeyBackend {
    private static let signature: OSType = 0x4F52_4159
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var action: ((UInt32) -> Void)?

    func installHandler(_ action: @escaping (UInt32) -> Void) throws {
        self.action = action
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == 0x4F52_4159 else { return OSStatus(eventNotHandledErr) }
                // Carbon dispatches application events on the application's main run loop.
                MainActor.assumeIsolated {
                    Unmanaged<CarbonHotKeyBackend>.fromOpaque(context).takeUnretainedValue().action?(identifier.id)
                }
                return noErr
            }, 1, &type, pointer, &handler)
        guard status == noErr else {
            self.action = nil
            throw LibraryValidationError("Global shortcuts could not be installed (\(status)).")
        }
    }

    func register(_ shortcut: CommandShortcut, identifier: UInt32) throws {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: identifier), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw LibraryValidationError(
                "macOS could not register \(shortcut.title); another app may use it (\(status)).")
        }
        references[identifier] = reference
    }

    func unregister(identifier: UInt32) {
        if let reference = references.removeValue(forKey: identifier) { UnregisterEventHotKey(reference) }
    }

    func removeHandler() {
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        action = nil
    }
}
