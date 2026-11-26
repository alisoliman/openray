import AppKit
import SwiftUI

extension SettingsPane {
    static let shortcuts = SettingsPane(
        id: "shortcuts", title: "Shortcuts",
        subtitle: "Open OpenRay, or jump straight to a command from any app.",
        kind: .command, symbol: "keyboard",
        keywords: "hotkey keyboard alias command global shortcut option space"
    ) { model, navigation in AnyView(ShortcutsPane(model: model, navigation: navigation)) }
}

struct ShortcutsPane: View {
    @Bindable var model: LauncherModel
    @Bindable var navigation: SettingsNavigation
    @State private var reservedShortcuts: Set<CommandShortcut> = []
    @State private var hotKeyPickerRevision = 0
    @State private var highlightedCommandID: String?
    /// An app, quicklink or snippet Settings was opened for, listed until the pane closes.
    @State private var extraRowID: String?

    var body: some View {
        ScrollViewReader { proxy in
            SettingsPaneScaffold(pane: .shortcuts) {
                Section("Launcher") {
                    // The model validates the choice; a reserved shortcut is refused and explained below.
                    // A refused choice rebuilds the picker, so it shows the shortcut still in use.
                    Picker(
                        "Show and hide OpenRay",
                        selection: Binding(
                            get: { model.store.database.preferences.hotKey },
                            set: { if !model.setLauncherHotKey($0) { hotKeyPickerRevision += 1 } })
                    ) {
                        ForEach(LauncherHotKey.allCases) { Text(hotKeyTitle($0)).tag($0) }
                    }
                    .neutralMenus()
                    .id(hotKeyPickerRevision)
                    if let error = model.launcherHotKeyRefusal ?? model.shortcutError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(OR.Color.warning)
                            .font(.system(size: 12))
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        Text("Command").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Alias").frame(width: 104, alignment: .leading)
                        Text("Shortcut").frame(width: 176, alignment: .leading)
                    }
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(commands) { command in
                        CommandBindingRow(
                            model: model, command: command, isFocusTarget: highlightedCommandID == command.id
                        )
                        .id(command.id)
                    }
                } header: {
                    HStack {
                        Text("Commands")
                        Spacer()
                        Text("Aliases are typed in the launcher; shortcuts work anywhere").fontWeight(.regular)
                    }
                }
            }
            .onAppear {
                reservedShortcuts = CommandShortcutPolicy.systemReservedShortcuts()
                focusRequestedCommand(proxy)
            }
            .onChange(of: navigation.focusCommandID) { focusRequestedCommand(proxy) }
        }
    }

    /// While searching, only the commands whose title or alias matches. All of them when
    /// none do, because then the pane itself matched.
    private var commands: [LauncherItem] {
        let all = model.bindingRows(focusing: extraRowID)
        let query = navigation.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let matching = all.filter { SettingsSearch.wordPrefixScore(query, in: model.settingsSearchText(for: $0)) != nil }
        return matching.isEmpty ? all : matching
    }

    private func hotKeyTitle(_ hotKey: LauncherHotKey) -> String {
        guard reservedShortcuts.contains(hotKey.shortcut) else { return hotKey.title }
        // Control-Space variants are the Input Sources defaults; anything else is some other system shortcut.
        let owner = hotKey.shortcut.modifiers.contains(.control) ? "Input Sources" : "macOS"
        return "\(hotKey.title) — used by \(owner)"
    }

    /// Scrolls to the command Settings was opened for, highlights it briefly and focuses its alias.
    private func focusRequestedCommand(_ proxy: ScrollViewProxy) {
        guard let id = navigation.focusCommandID else { return }
        navigation.focusCommandID = nil
        guard model.bindingRows(focusing: id).contains(where: { $0.id == id }) else { return }
        extraRowID = id
        if !commands.contains(where: { $0.id == id }) { navigation.search = "" }
        // Wait a turn, so the rows exist when the pane has only just appeared.
        Task { @MainActor in
            proxy.scrollTo(id, anchor: .center)
            highlightedCommandID = id
            try? await Task.sleep(for: .seconds(1.6))
            if highlightedCommandID == id { highlightedCommandID = nil }
        }
    }
}

struct CommandBindingRow: View {
    let model: LauncherModel
    let command: LauncherItem
    var isFocusTarget = false
    @State private var alias = ""
    @State private var aliasError: String?
    @State private var isRecording = false
    @State private var pending: CommandBinding?
    @State private var warnings: [String] = []
    @State private var error: String?
    @FocusState private var aliasFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mainRow
            if let problem { problemRow(problem) }
        }
        .background {
            RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous)
                .fill(OR.Color.accentSoft)
                .padding(-4)
                .opacity(isFocusTarget ? 1 : 0)
        }
        .animation(OR.Motion.resolve(OR.Motion.standard, reduceMotion: reduceMotion), value: isFocusTarget)
        .onAppear { alias = model.commandBinding(for: command.id).alias ?? "" }
        .onChange(of: isFocusTarget, initial: true) { _, target in if target { aliasFocused = true } }
        // A typed alias is committed when the row goes away (search, pane change or window close).
        // saveAlias is a no-op when nothing changed.
        .onDisappear {
            saveAlias()
            stop()
        }
    }

    private var mainRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                KindTile(kind: command.kind, symbol: command.symbol, size: 18)
                Text(command.title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            aliasField
            recorder
        }
    }

    private var aliasField: some View {
        TextField("Alias", text: $alias, prompt: Text("Add alias"))
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: alias.isEmpty ? .default : .monospaced))
            // The same well as the shortcut recorder beside it.
            .fieldBox(focused: aliasFocused, minHeight: 28)
            .frame(width: 104)
            .focused($aliasFocused)
            .onSubmit { saveAlias() }
            .onChange(of: aliasFocused) { _, focused in if !focused { saveAlias() } }
            .accessibilityLabel("Alias for \(command.title)")
            .accessibilityIdentifier("commandBinding.alias.\(command.id)")
    }

    private var recorder: some View {
        let shortcut = (pending ?? model.commandBinding(for: command.id)).shortcut
        let clearAction: (() -> Void)? = shortcut == nil ? nil : { clear() }
        return ShortcutRecorderControl(
            title: command.title,
            shortcut: shortcut, isRecording: isRecording,
            hasWarning: !warnings.isEmpty || model.commandShortcutErrors[command.id] != nil,
            minWidth: 176,
            onStart: { start() }, onStop: { stop() }, onRecord: { record($0) },
            onClear: clearAction
        )
        .frame(width: 176)
        .accessibilityIdentifier("commandBinding.recordShortcut.\(command.id)")
    }

    private func problemRow(_ problem: (text: String, canKeep: Bool, isError: Bool)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(problem.text).fixedSize(horizontal: false, vertical: true)
            if problem.canKeep {
                Button("Keep Anyway") { keepAnyway() }.buttonStyle(.link)
                Button("Undo") {
                    pending = nil
                    warnings = []
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(problem.isError ? OR.Color.danger : OR.Color.warning)
        .padding(.leading, 26)
    }

    private var problem: (text: String, canKeep: Bool, isError: Bool)? {
        if let aliasError { return (aliasError, false, true) }
        if let error { return (error, false, true) }
        if !warnings.isEmpty { return (warnings.joined(separator: " "), true, false) }
        if let issue = model.commandShortcutErrors[command.id] { return (issue, false, false) }
        return nil
    }

    /// Why the last write failed. A failed save always replaces the model's feedback with its
    /// reason, while the store's message can be an older notice, so feedback comes first.
    private func saveFailure(_ fallback: String) -> String {
        model.message ?? model.store.errorMessage ?? fallback
    }

    private func saveAlias() {
        var binding = model.commandBinding(for: command.id)
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard trimmed != (binding.alias ?? "") else {
            aliasError = nil
            return
        }
        binding.alias = trimmed.isEmpty ? nil : trimmed
        do {
            try model.validateCommandBinding(binding)
            let saved =
                binding.isEmpty
                ? model.removeCommandBinding(for: command.id) : model.saveCommandBinding(binding, allowConflicts: true)
            // Keep the typed text, so the error stays next to what was typed.
            aliasError = saved ? nil : saveFailure("The alias couldn't be saved.")
        } catch {
            aliasError = error.localizedDescription
        }
    }

    private func start() {
        error = nil
        model.beginShortcutRecording()
        isRecording = true
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        model.endShortcutRecording()
    }

    private func record(_ event: NSEvent) {
        defer { stop() }
        if CommandShortcutRecording.isRemoveKey(event) {
            clear()
            return
        }
        do {
            var binding = model.commandBinding(for: command.id)
            binding.shortcut = try CommandShortcutRecording.shortcut(from: event)
            try model.validateCommandBinding(binding)
            let found = model.bindingWarnings(for: binding)
            if found.isEmpty {
                warnings = []
                pending = nil
                error = model.saveCommandBinding(binding) ? nil : model.message
            } else {
                warnings = found
                pending = binding
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Saves only the pending shortcut into the current binding, so an alias saved
    /// while the warning was showing is kept.
    private func keepAnyway() {
        guard let shortcut = pending?.shortcut else { return }
        var binding = model.commandBinding(for: command.id)
        binding.shortcut = shortcut
        let saved = model.saveCommandBinding(binding, allowConflicts: true)
        pending = nil
        warnings = []
        error = saved ? nil : saveFailure("The shortcut couldn't be saved.")
    }

    private func clear() {
        pending = nil
        warnings = []
        error = nil
        var binding = model.commandBinding(for: command.id)
        guard binding.shortcut != nil else { return }
        binding.shortcut = nil
        let saved =
            binding.isEmpty
            ? model.removeCommandBinding(for: command.id) : model.saveCommandBinding(binding, allowConflicts: true)
        if !saved { error = saveFailure("The shortcut couldn't be removed.") }
    }
}
