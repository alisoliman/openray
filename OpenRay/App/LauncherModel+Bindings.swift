import AppKit

extension LauncherModel {
    func commandBinding(for targetID: String) -> CommandBinding {
        store.database.binding(for: targetID) ?? CommandBinding(targetID: targetID)
    }

    func bindingWarnings(for binding: CommandBinding) -> [String] {
        guard let shortcut = binding.shortcut else { return [] }
        var warnings = CommandShortcutPolicy.conflictWarnings(for: shortcut)
        if shortcut == store.database.preferences.hotKey.shortcut {
            warnings.append("It opens OpenRay, so this command won't use it while the launcher does.")
        }
        for other in store.database.commandBindings
        where other.targetID != binding.targetID && other.shortcut == shortcut {
            let title = bindableCommands.first { $0.id == other.targetID }?.title ?? other.targetID
            warnings.append("It's also assigned to \(title), and only the first one saved can work.")
        }
        return warnings
    }

    @discardableResult
    func saveCommandBinding(_ binding: CommandBinding, allowConflicts: Bool = false) -> Bool {
        do {
            try validateCommandBinding(binding)
            let warnings = bindingWarnings(for: binding)
            guard allowConflicts || warnings.isEmpty else {
                feedback = .warning(warnings.joined(separator: " ") + " Choose Keep Anyway to save it.")
                return false
            }
            guard store.saveCommandBinding(binding) else {
                feedback = store.errorMessage.map { .error($0) }
                return false
            }
            feedback = commandShortcutErrors[binding.targetID].map { .warning($0) }
            synchronizeSelection()
            return true
        } catch {
            feedback = .error(error.localizedDescription)
            return false
        }
    }

    func validateCommandBinding(_ binding: CommandBinding) throws {
        try binding.validate()
        if let shortcut = binding.shortcut {
            try CommandShortcutPolicy.validate(
                shortcut: shortcut, reservedShortcuts: CommandShortcutPolicy.systemReservedShortcuts())
        }
        var candidate = store.database
        candidate.commandBindings.removeAll { $0.targetID == binding.targetID }
        if !binding.isEmpty { candidate.commandBindings.append(binding) }
        try candidate.validate()
    }

    @discardableResult
    func removeCommandBinding(for targetID: String) -> Bool {
        guard store.removeCommandBinding(for: targetID) else {
            feedback = store.errorMessage.map { .error($0) }
            return false
        }
        synchronizeSelection()
        return true
    }

    func beginShortcutRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        hotKey.unregister()
    }

    func beginCommandBindingEditing() { commandBindingEditorCount += 1 }

    func endCommandBindingEditing() { commandBindingEditorCount = max(0, commandBindingEditorCount - 1) }

    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        synchronizeCommandHotKeys()
    }

    func synchronizeCommandHotKeys() {
        guard isStarted, !isRecordingShortcut else { return }
        // The refusal was about an earlier choice; registration below reports the current state.
        launcherHotKeyRefusal = nil
        guard clipboard.usesGeneralPasteboard else {
            hotKey.unregister()
            shortcutError = nil
            commandShortcutErrors = [:]
            return
        }
        let stored = store.database.preferences.hotKey
        let bindings = store.database.commandBindings
        // A saved choice macOS now reserves (Input Sources, say) would leave no way
        // to open OpenRay, so register the first choice that works without saving it.
        let launcher =
            Self.launcherHotKey(
                for: stored, reserved: CommandShortcutPolicy.systemReservedShortcuts(),
                boundShortcuts: Set(bindings.compactMap(\.shortcut))) ?? stored
        let issues = hotKey.synchronize(
            launcher: launcher, bindings: bindings,
            onLauncher: { [weak self] in self?.launcherHotKeyPressed() },
            onCommand: { [weak self] in self?.performBoundCommand(targetID: $0) },
            title: { [weak self] id in self?.bindableCommands.first { $0.id == id }?.title })
        let launcherIssue = issues.first { $0.targetID == GlobalHotKey.launcherTargetID }?.message
        if launcher == stored {
            shortcutError = launcherIssue
        } else {
            let reason = Self.reservedLauncherHotKeyMessage(stored)
            shortcutError =
                launcherIssue.map { reason + " " + $0 }
                ?? "\(reason) Until then, \(launcher.title) opens OpenRay."
        }
        commandShortcutErrors = Dictionary(
            issues.filter { $0.targetID != GlobalHotKey.launcherTargetID }.map { ($0.targetID, $0.message) },
            uniquingKeysWith: { first, second in first + " " + second })
    }

    /// The launcher shortcut to register: the saved one when macOS allows it,
    /// otherwise the first other choice macOS allows, preferring one no command
    /// uses. Nil when macOS reserves every choice.
    nonisolated static func launcherHotKey(
        for stored: LauncherHotKey, reserved: Set<CommandShortcut>, boundShortcuts: Set<CommandShortcut>
    ) -> LauncherHotKey? {
        func isAllowed(_ value: LauncherHotKey) -> Bool {
            (try? CommandShortcutPolicy.validate(shortcut: value.shortcut, reservedShortcuts: reserved)) != nil
        }
        if isAllowed(stored) { return stored }
        let others = LauncherHotKey.allCases.filter { $0 != stored && isAllowed($0) }
        return others.first { !boundShortcuts.contains($0.shortcut) } ?? others.first
    }

    nonisolated static func reservedLauncherHotKeyMessage(_ value: LauncherHotKey) -> String {
        let owner = value == .optionSpace ? "a macOS keyboard shortcut" : "Input Sources"
        return "\(value.title) is used by \(owner). "
            + "Turn it off in System Settings › Keyboard › Keyboard Shortcuts, or pick another shortcut."
    }

    /// Saves the launcher shortcut only when macOS lets it work. Otherwise the
    /// saved one stays, and launcherHotKeyRefusal says why the choice was refused.
    /// The refusal is kept apart from shortcutError, which describes the shortcut
    /// that is registered, so it never blocks or misreports the one that works.
    @discardableResult
    func setLauncherHotKey(_ value: LauncherHotKey) -> Bool {
        do {
            try CommandShortcutPolicy.validate(
                shortcut: value.shortcut, reservedShortcuts: CommandShortcutPolicy.systemReservedShortcuts())
        } catch {
            launcherHotKeyRefusal = Self.reservedLauncherHotKeyMessage(value)
            return false
        }
        // A failed write keeps the working shortcut; the library error explains it.
        guard store.update({ $0.preferences.hotKey = value }) else { return false }
        launcherHotKeyRefusal = nil
        // Registration below reports any new problem.
        shortcutError = nil
        applyPreferences()
        return true
    }

    /// During first run, pressing the shortcut is the lesson, not a toggle. A
    /// fallback or failing shortcut isn't the one the lesson names, so it doesn't count.
    /// A press does prove the saved shortcut works, so an earlier refusal is done with.
    func launcherHotKeyPressed() {
        if onboarding == .shortcut, panel?.isVisible == true {
            if shortcutError == nil {
                launcherHotKeyRefusal = nil
                onboardingHotKeyPressed = true
            }
            return
        }
        panel?.toggle()
    }

    /// Global invocations use the same dispatch as selected search results.
    /// Resolve again at delivery so a removed or disallowed target cannot run.
    func performBoundCommand(targetID: String) {
        guard !isRecordingShortcut, commandBindingEditorCount == 0,
            store.database.binding(for: targetID)?.shortcut != nil,
            let command = bindableCommands.first(where: { $0.id == targetID })
        else { return }
        // Showing can reset to Home, which clears feedback and closes a clean
        // editor, so show first and only then decide what to say.
        if editor != nil {
            panel?.show()
            guard editor == nil else {
                feedback = .warning("Save or cancel the current editor before using a command shortcut.")
                return
            }
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        if runsWithoutPanel(command) {
            perform(command)
            if let pending = feedback {
                panel?.show()
                feedback = pending
            }
        } else {
            panel?.show()
            perform(command)
        }
    }

    /// Window layouts and provided commands with `mode: .noView` act on the app you're in,
    /// so a hotkey runs them without showing the panel. The panel shows only to report a problem.
    func runsWithoutPanel(_ command: LauncherItem) -> Bool {
        switch command.action {
        case .window: true
        case .provided(let ref): registry.descriptor(for: ref, in: self)?.mode == .noView
        default: false
        }
    }
}
