import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, shortcuts, clipboard, snippets, files, ai, permissions, library, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .clipboard: "Clipboard"
        case .snippets: "Snippets"
        case .files: "Files"
        case .ai: "Apple Intelligence"
        case .permissions: "Permissions"
        case .library: "Library"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "How OpenRay looks and opens."
        case .shortcuts: "Open OpenRay, or jump straight to a command from any app."
        case .clipboard: "What OpenRay keeps from your clipboard, and for how long."
        case .snippets: "Text that expands from a keyword as you type."
        case .files: "Where Files looks, using your existing Spotlight index."
        case .ai: "Ask AI and writing commands, on this Mac."
        case .permissions: "OpenRay works without any of these. Each one unlocks specific features."
        case .library: "Your notes, snippets, quicklinks and history, stored on this Mac."
        case .about: "Version, help and privacy."
        }
    }

    var kind: Kind {
        switch self {
        case .general: .system
        case .shortcuts: .command
        case .clipboard: .clipboard
        case .snippets: .snippet
        case .files: .file
        case .ai: .ai
        case .permissions: .permission
        case .library: .system
        case .about: .about
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .shortcuts: "keyboard"
        case .clipboard: "list.clipboard"
        case .snippets: "curlybraces"
        case .files: "folder"
        case .ai: "sparkles"
        case .permissions: "checkmark.shield"
        case .library: "books.vertical"
        case .about: "info"
        }
    }

    /// Words the sidebar search matches, so search finds settings, not just pane names.
    var keywords: String {
        switch self {
        case .general: "appearance light dark theme bar mode compact remember last query search applications index refresh"
        case .shortcuts: "hotkey keyboard alias command global shortcut option space"
        case .clipboard: "history capture pause retention days entries exclude apps password delete storage images files"
        case .snippets: "keyword expand expansion type"
        case .files: "spotlight folder search home documents downloads desktop developer"
        case .ai: "apple intelligence model on-device privacy chat writing"
        case .permissions: "accessibility clipboard access login spotlight privacy allow"
        case .library: "reveal finder export data location backup json"
        case .about: "version help guide privacy support issue feedback"
        }
    }

    static let primary: [SettingsPane] = [.general, .shortcuts, .clipboard, .snippets, .files, .ai]
    static let secondary: [SettingsPane] = [.permissions, .library, .about]
}

@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .general
    var search = ""
    /// A command row to scroll to and focus when the Shortcuts pane shows. Cleared once handled.
    var focusCommandID: String?
}

struct SettingsWindowView: View {
    @Bindable var model: LauncherModel
    @Bindable var navigation: SettingsNavigation
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) {
                Section {
                    ForEach(filtered(SettingsPane.primary)) { sidebarRow($0) }
                }
                Section {
                    ForEach(filtered(SettingsPane.secondary)) { sidebarRow($0) }
                }
            }
            .searchable(text: $navigation.search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 260)
        } detail: {
            if !query.isEmpty, filtered(SettingsPane.allCases).isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                // Panes are tinted with Ray rather than the system accent. The text token, not the
                // fill token, because the tint also colors button titles and pop-up values. The
                // sidebar keeps native selection: neutral, and Ray only while it has keyboard focus.
                pane
                    .tint(OR.Color.accent)
                    .navigationTitle(navigation.pane.title)
                    .navigationSubtitle(paneSubtitle)
            }
        }
        .environment(\.settingsStoreError, storeError)
        .appAppearance(model.store.database.preferences.appearance)
        .onChange(of: activeState) { if activeState == .key { model.refreshPermissions() } }
        .onChange(of: navigation.search) {
            guard !query.isEmpty,
                let best = SettingsSearch.bestPane(for: query, commands: commandSearchTexts)
            else { return }
            navigation.pane = best
        }
        .frame(minWidth: 700, minHeight: 460)
    }

    private var query: String { navigation.search.trimmingCharacters(in: .whitespaces) }

    private var commandSearchTexts: [String] { model.bindableCommands.map { model.settingsSearchText(for: $0) } }

    /// A library that failed to load can't save anything, so every pane says so once, at the top.
    private var storeError: String? {
        guard model.store.isReadOnly else { return nil }
        return model.store.errorMessage ?? "Your library couldn't be loaded, so changes here aren't saved."
    }

    private var paneSubtitle: String {
        guard navigation.pane == .clipboard, !model.store.database.clipboard.isEmpty else { return navigation.pane.subtitle }
        let entries = model.store.database.clipboard
        let bytes = entries.reduce(0) { $0 + $1.byteCount }
        return "\(entries.count.formatted()) entr\(entries.count == 1 ? "y" : "ies") · "
            + "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of "
            + ByteCountFormatter.string(fromByteCount: Int64(ClipboardLimits.historyBytes), countStyle: .file)
    }

    private func filtered(_ panes: [SettingsPane]) -> [SettingsPane] {
        guard !query.isEmpty else { return panes }
        let commands = commandSearchTexts
        return panes.filter { SettingsSearch.score($0, query: query, commands: commands) != nil }
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            KindTile(kind: pane.kind, symbol: pane.symbol, size: 20)
        }
        .tag(pane)
        .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
    }

    @ViewBuilder private var pane: some View {
        switch navigation.pane {
        case .general: GeneralPane(model: model)
        case .shortcuts: ShortcutsPane(model: model, navigation: navigation)
        case .clipboard: ClipboardPane(model: model)
        case .snippets: SnippetsPane(model: model)
        case .files: FilesPane(model: model)
        case .ai: AIPane(model: model)
        case .permissions: PermissionsPane(model: model)
        case .library: LibraryPane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

/// Sidebar search. Pane titles use the launcher's matcher. Keywords and command names must match
/// whole-word prefixes, so a scattered run of letters can't jump to an unrelated pane.
enum SettingsSearch {
    /// How well a pane matches, or nil when it doesn't. `commands` are the bindable commands'
    /// titles and aliases; a match there keeps Shortcuts in the results.
    static func score(_ pane: SettingsPane, query: String, commands: [String] = []) -> Int? {
        let title = SearchMatcher.score(query, in: pane.title)
        // Keyword and command matches rank below the same kind of match on a pane title.
        let keywords = wordPrefixScore(query, in: pane.title + " " + pane.keywords).map { $0 - 50 }
        let command =
            pane == .shortcuts ? commands.compactMap { wordPrefixScore(query, in: $0) }.max().map { $0 - 150 } : nil
        return [title, keywords, command].compactMap { $0 }.max()
    }

    /// The best-scoring pane. Ties keep sidebar order.
    static func bestPane(for query: String, commands: [String] = []) -> SettingsPane? {
        var best: (pane: SettingsPane, score: Int)?
        for pane in SettingsPane.primary + SettingsPane.secondary {
            guard let paneScore = Self.score(pane, query: query, commands: commands),
                paneScore > (best?.score ?? .min)
            else { continue }
            best = (pane, paneScore)
        }
        return best?.pane
    }

    /// Every query term must be a whole word (700) or start a word (600) in `text`, averaged.
    /// Folded case- and diacritic-insensitively.
    static func wordPrefixScore(_ query: String, in text: String) -> Int? {
        let terms = Self.words(in: query)
        guard !terms.isEmpty else { return nil }
        let candidates = Self.words(in: text)
        var total = 0
        for term in terms {
            if candidates.contains(term) {
                total += 700
            } else if candidates.contains(where: { $0.hasPrefix(term) }) {
                total += 600
            } else {
                return nil
            }
        }
        return total / terms.count
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static func words(in value: String) -> [String] {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

extension EnvironmentValues {
    /// Why Settings can't save, shown once at the top of each pane. Nil when the library is writable.
    @Entry var settingsStoreError: String? = nil
}

/// A pane: native grouped form sections. The title and description live in the toolbar.
struct SettingsPaneScaffold<Content: View>: View {
    var pane: SettingsPane
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.settingsStoreError) private var storeError

    var body: some View {
        Form {
            if let storeError {
                Section {
                    Label {
                        SettingRowLabel(title: "Changes can't be saved", detail: storeError)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(OR.Color.danger)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            content
        }
        .formStyle(.grouped)
    }
}

private struct SettingRowLabel: View {
    var title: String
    var detail: String?
    /// A disabled row dims its words too, not only its control.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(isEnabled ? .primary : .tertiary)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(isEnabled ? .secondary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension LauncherModel {
    func preference<Value>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.store.database.preferences[keyPath: path] },
            set: { value in
                if self.store.update({ $0.preferences[keyPath: path] = value }) { self.applyPreferences() }
            })
    }

    func optionalPreference(_ path: WritableKeyPath<AppPreferences, Bool?>, default fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { self.store.database.preferences[keyPath: path] ?? fallback },
            set: { value in
                if self.store.update({ $0.preferences[keyPath: path] = value }) { self.applyPreferences() }
            })
    }

    /// A bindable command's title and alias, which the Settings search matches.
    func settingsSearchText(for command: LauncherItem) -> String {
        [command.title, commandBinding(for: command.id).alias].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .general) {
            Section("Appearance") {
                // The design's neutral segmented control: a selected segment isn't a red alert. An
                // HStack, because a form's LabeledContent ignores the control's text baseline.
                HStack(alignment: .firstTextBaseline) {
                    Text("Appearance")
                    Spacer()
                    SegmentedPicker(
                        options: AppAppearance.allCases.map { ($0, $0.title) }, selection: model.preference(\.appearance),
                        accessibilityLabel: "Appearance")
                }
                Toggle(isOn: model.optionalPreference(\.barMode)) {
                    SettingRowLabel(title: "Start as a search bar", detail: "Show only the field until you type, like Spotlight.")
                }
                .settingsSwitch()
            }
            Section("Search") {
                Toggle(isOn: model.optionalPreference(\.rememberLastQuery, default: true)) {
                    SettingRowLabel(
                        title: "Remember the last search for 90 seconds",
                        detail: "Reopening OpenRay shows it selected, so typing replaces it.")
                }
                .settingsSwitch()
                LabeledContent {
                    Button(model.applications.isLoading ? "Refreshing…" : "Refresh") {
                        Task { await model.applications.refresh() }
                    }
                    .disabled(model.applications.isLoading)
                } label: {
                    SettingRowLabel(
                        title: "Applications",
                        detail: "\(model.applications.applications.count.formatted()) apps indexed from your Applications folders")
                }
            }
            Section("Getting started") {
                LabeledContent {
                    Button("Show Again") {
                        model.store.update { $0.preferences.firstRunCompleted = false }
                        model.panel?.show()
                    }
                } label: {
                    SettingRowLabel(title: "First-run guide", detail: "The three-step introduction to OpenRay.")
                }
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @Bindable var model: LauncherModel
    @Bindable var navigation: SettingsNavigation
    @State private var reservedShortcuts: Set<CommandShortcut> = []
    @State private var hotKeyPickerRevision = 0
    @State private var highlightedCommandID: String?

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
        let all = model.bindableCommands
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
        guard model.bindableCommands.contains(where: { $0.id == id }) else { return }
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

private struct CommandBindingRow: View {
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

// MARK: - Clipboard

private struct ClipboardPane: View {
    @Bindable var model: LauncherModel
    @State private var confirmClear = false
    @State private var confirmOff = false

    enum CaptureState: Hashable { case on, paused, off }

    var body: some View {
        let preferences = model.store.database.preferences
        let entries = model.store.database.clipboard
        let bytes = entries.reduce(0) { $0 + $1.byteCount }
        SettingsPaneScaffold(
            pane: .clipboard,
            subtitle: entries.isEmpty
                ? "What OpenRay keeps from your clipboard, and for how long."
                : "\(entries.count.formatted()) entr\(entries.count == 1 ? "y" : "ies") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(ClipboardLimits.historyBytes), countStyle: .file))"
        ) {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    SettingRowLabel(
                        title: "Save clipboard history",
                        detail: "Paused keeps history searchable. Off asks whether to delete it.")
                    Spacer()
                    SegmentedPicker(
                        options: [(CaptureState.on, "On"), (.paused, "Paused"), (.off, "Off")], selection: captureBinding,
                        accessibilityLabel: "Save clipboard history")
                }
                // What gets captured only matters while capturing.
                let isOff = captureBinding.wrappedValue == .off
                Toggle(isOn: model.optionalPreference(\.clipboardImagesEnabled)) {
                    SettingRowLabel(title: "Include images", detail: "PNG, up to 10 MB each")
                }
                .settingsSwitch()
                .disabled(isOff)
                Toggle(isOn: model.optionalPreference(\.clipboardFilesEnabled)) {
                    SettingRowLabel(title: "Include files", detail: "References only. Originals are never copied or changed.")
                }
                .settingsSwitch()
                .disabled(isOff)
                LabeledContent {
                    HStack {
                        Picker("Days", selection: model.preference(\.clipboardRetentionDays)) {
                            Text("1 day").tag(1)
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                        }
                        .labelsHidden().fixedSize()
                        Picker("Entries", selection: model.preference(\.clipboardLimit)) {
                            ForEach([50, 100, 250, 500], id: \.self) { Text("\($0) entries").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .neutralMenus()
                } label: {
                    SettingRowLabel(title: "Keep entries for")
                }
                // Retention still prunes saved history while capture is off.
                .disabled(isOff && entries.isEmpty)
                if let note = model.clipboard.accessMessage {
                    Label(note, systemImage: "hand.raised.fill").font(.system(size: 12)).foregroundStyle(OR.Color.warning)
                }
            } footer: {
                Text("Pinned entries are kept until you unpin or delete them. Everything stays within the 64 MB history budget.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ExclusionsSection(model: model)
            Section {
                HStack {
                    Spacer()
                    Button("Delete All History…", role: .destructive) { confirmClear = true }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .confirmationDialog("Delete all clipboard history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete All History", role: .destructive) { deleteAllHistory() }
        } message: {
            Text(deleteAllMessage(entries))
        }
        .confirmationDialog("Turn off clipboard history?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Delete History and Turn Off", role: .destructive) {
                setCapture(enabled: false, paused: false)
                model.clipboard.clearHistory()
            }
            Button("Keep History (Pause)") { setCapture(enabled: false, paused: true) }
        } message: {
            Text(turnOffMessage(entries))
        }
        .onChange(of: preferences.clipboardEnabled) { model.clipboard.refreshAccessStatus() }
    }

    /// Reads the stored Paused state, so pruning or deleting history while paused doesn't show Off.
    private var captureBinding: Binding<CaptureState> {
        Binding(
            get: {
                let database = model.store.database
                if database.preferences.clipboardEnabled { return .on }
                return database.clipboardIsPaused ? .paused : .off
            },
            set: { state in
                switch state {
                case .on: setCapture(enabled: true, paused: false)
                case .paused: setCapture(enabled: false, paused: true)
                case .off:
                    if model.store.database.clipboard.isEmpty {
                        setCapture(enabled: false, paused: false)
                    } else {
                        confirmOff = true
                    }
                }
            })
    }

    private func setCapture(enabled: Bool, paused: Bool) {
        if model.store.update({
            $0.preferences.clipboardEnabled = enabled
            $0.preferences.clipboardPaused = paused
        }) {
            model.applyPreferences()
        }
    }

    /// A pause inferred from saved history stays Paused; LibraryStore records it as the history goes.
    private func deleteAllHistory() {
        model.clipboard.clearHistory()
    }

    private func deleteAllMessage(_ entries: [ClipboardEntry]) -> String {
        let pinned = entries.filter(\.isPinned).count
        guard pinned > 0 else {
            return "This removes the saved history from OpenRay. Your current clipboard stays as it is."
        }
        return "This removes the saved history from OpenRay, including \(Self.entryPhrase(pinned, "pinned")). "
            + "Your current clipboard stays as it is."
    }

    private func turnOffMessage(_ entries: [ClipboardEntry]) -> String {
        let pinned = entries.filter(\.isPinned).count
        let saved = "\(Self.entryPhrase(entries.count, "saved")) \(entries.count == 1 ? "is" : "are") still on this Mac."
        return pinned > 0 ? saved + " This also deletes \(Self.entryPhrase(pinned, "pinned"))." : saved
    }

    /// "1 pinned entry", "3 pinned entries".
    private static func entryPhrase(_ count: Int, _ adjective: String) -> String {
        "\(count.formatted()) \(adjective) entr\(count == 1 ? "y" : "ies")"
    }
}

/// Exclusions use an app picker. Built-in exclusions are listed and locked.
private struct ExclusionsSection: View {
    let model: LauncherModel

    var body: some View {
        // Built-ins always apply, even when an older library's stored list dropped them.
        let ids = model.store.database.preferences.effectiveClipboardExclusions
        // Rows of the group itself, as System Settings lists login items, not a list boxed inside it.
        Section {
            ForEach(ids, id: \.self) { id in
                let name = displayName(for: id)
                HStack(spacing: 10) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        WorkspaceIcon(url: url, size: 20)
                        Text(name)
                    } else if Self.knownNames[id] != nil {
                        Image(systemName: "lock.square").font(.system(size: 16)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                        Text(name)
                        Text("Not installed").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "app.dashed").frame(width: 20, height: 20)
                        Text(id).font(.system(size: 12, design: .monospaced))
                    }
                    Spacer()
                    if AppPreferences.builtInClipboardExclusions.contains(id) {
                        Label("Always excluded", systemImage: "lock.fill").labelStyle(TightLabelStyle())
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Button("Remove") { remove(id) }
                            .accessibilityLabel("Remove \(name)")
                    }
                }
            }
            Button { addApp() } label: { Label("Add App…", systemImage: "plus") }
                .buttonStyle(.borderless)
        } header: {
            Text("Never save from these apps")
        } footer: {
            Text("Copies made in these apps are never captured, and snippets don't expand there.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    static let knownNames = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden", "com.apple.Passwords": "Passwords", "org.keepassxc.keepassxc": "KeePassXC",
    ]

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to exclude"
        panel.prompt = "Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        guard !added.isEmpty else { return }
        if model.store.update({
            $0.preferences.excludedClipboardBundleIDs = Array(
                NSOrderedSet(array: $0.preferences.excludedClipboardBundleIDs + added)) as? [String] ?? []
        }) {
            model.applyPreferences()
        }
    }

    private func displayName(for id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return Self.knownNames[id] ?? id
    }

    private func remove(_ id: String) {
        guard !AppPreferences.builtInClipboardExclusions.contains(id) else { return }
        if model.store.update({ $0.preferences.excludedClipboardBundleIDs.removeAll { $0 == id } }) {
            model.applyPreferences()
        }
    }
}

// MARK: - Snippets

private struct SnippetsPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .snippets) {
            Section {
                Toggle(isOn: model.preference(\.snippetExpansionEnabled)) {
                    SettingRowLabel(
                        title: "Expand keywords as I type",
                        detail: "Only a short keyword buffer is held in memory. Typing is never saved. Skipped during Secure Input and in excluded apps.")
                }
                .settingsSwitch()
                .disabled(!model.accessibilityAllowed)
                if !model.accessibilityAllowed {
                    LabeledContent {
                        Button("Enable…") {
                            model.windows.requestPermission()
                            SystemSettingsLink.open(.accessibility)
                        }
                    } label: {
                        Label("Needs Accessibility, which is off.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(OR.Color.warning).font(.system(size: 12))
                    }
                }
            }
            Section("Snippets with keywords") {
                let snippets = model.store.database.snippets.filter { !$0.keyword.isEmpty }
                if snippets.isEmpty {
                    Text("Snippets you give a keyword appear here. Create them from the Snippets command.")
                        .foregroundStyle(.secondary).font(.system(size: 12.5))
                }
                ForEach(snippets) { snippet in
                    Toggle(isOn: Binding(
                        get: { snippet.expandsAsYouType },
                        set: { value in
                            var updated = snippet
                            updated.expandsKeyword = value ? nil : false
                            model.store.save(updated)
                        })
                    ) {
                        HStack(spacing: 8) {
                            KindTile(kind: .snippet, size: 18)
                            Text(snippet.name)
                            AliasChip(text: snippet.keyword)
                        }
                    }
                    .settingsSwitch()
                    .disabled(!model.store.database.preferences.snippetExpansionEnabled)
                }
            }
        }
    }
}

// MARK: - Files

private struct FilesPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .files) {
            Section {
                Picker("Search in", selection: $model.fileScope) {
                    ForEach(FileSearchScope.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .neutralMenus()
            } footer: {
                Text("You can change this in the Files scope too. Narrowing to one folder makes results faster and tighter.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Always skipped") {
                IconRow("Hidden files and folders", symbol: "eye.slash")
                IconRow("Your Library folder", symbol: "books.vertical")
                IconRow("Build products such as node_modules and DerivedData", symbol: "hammer")
                IconRow("Applications, which appear in Everything instead", symbol: "square.grid.2x2")
            }
            Section {
                LabeledContent {
                    Button("Open Spotlight Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
                    }
                } label: {
                    SettingRowLabel(title: "Missing files?", detail: "Files uses your existing Spotlight index. Check that your home folder isn't excluded.")
                }
            }
        }
    }
}

// MARK: - Apple Intelligence

private struct AIPane: View {
    let model: LauncherModel

    var body: some View {
        let availability = model.ai.availability
        SettingsPaneScaffold(pane: .ai) {
            Section {
                LabeledContent {
                    StatusLabel(tone: availability.isAvailable ? .success : availability == .preparing ? .working : .warning, text: availability.shortStatus)
                } label: {
                    SettingRowLabel(title: availability.headline, detail: availability.detail)
                }
                ForEach(availability.requirements) { requirement in
                    LabeledContent {
                        Image(
                            systemName: requirement.state == .met
                                ? "checkmark.circle.fill" : requirement.state == .waiting ? "clock" : "exclamationmark.circle"
                        )
                        .foregroundStyle(
                            requirement.state == .met
                                ? OR.Color.success : requirement.state == .blocked ? OR.Color.warning : .secondary)
                            .accessibilityHidden(true)
                    } label: {
                        SettingRowLabel(title: requirement.title, detail: requirement.note)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(
                        requirement.state == .met ? "Done" : requirement.state == .waiting ? "In progress" : "Needed")
                }
                if !availability.isAvailable {
                    HStack {
                        Spacer()
                        Button("Check Again") { model.ai.refreshAvailability() }
                        Button("Open Apple Intelligence Settings") { AppleIntelligenceSettings.open() }
                            .buttonStyle(.borderedProminent).tint(OR.Color.accentButton)
                    }
                }
            }
            Section("Privacy") {
                IconRow("Runs on Apple's on-device model. Nothing is sent to a server, and there's no cloud fallback.", symbol: "lock.fill")
                IconRow("Clipboard and selected text reach the model only when you attach them or start a writing command.", symbol: "paperclip")
                IconRow("Chats are kept in memory. Save as Note is the only way a response is stored.", symbol: "note.text")
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    let model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .permissions) {
            Section {
                permission(
                    kind: .quicklink, symbol: "accessibility", title: "Accessibility",
                    detail: "Window layouts, Paste to app, selected text, snippet expansion"
                ) {
                    if model.accessibilityAllowed {
                        StatusLabel(tone: .success, text: "Allowed")
                    } else {
                        Button("Enable…") {
                            model.windows.requestPermission()
                            SystemSettingsLink.open(.accessibility)
                        }
                    }
                }
                permission(kind: .clipboard, symbol: nil, title: "Clipboard access", detail: clipboardDetail) {
                    clipboardStatus
                }
                permission(
                    kind: .system, symbol: "bolt", title: "Open at login",
                    detail: "Keeps \(model.store.database.preferences.hotKey.title) ready after a restart",
                    error: model.loginError
                ) {
                    if model.loginNeedsApproval {
                        Button("Approve…") { SMAppService.openSystemSettingsLoginItems() }
                    } else {
                        Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }))
                            .labelsHidden().toggleStyle(.switch).settingsSwitch()
                    }
                }
                permission(kind: .ai, symbol: nil, title: "Apple Intelligence", detail: "Ask AI and writing commands, on this Mac") {
                    let availability = model.ai.availability
                    StatusLabel(
                        tone: availability.isAvailable ? .success : availability == .preparing ? .working : .warning,
                        text: availability.shortStatus)
                }
                permission(kind: .file, symbol: "folder", title: "Spotlight", detail: "File search uses your existing Spotlight index") {
                    StatusLabel(tone: .success, text: "In use")
                }
            } footer: {
                Label("Status refreshes when you come back to this window.", systemImage: "arrow.clockwise")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Fix… opens System Settings, so say first which choice to make there.
    private var clipboardDetail: String {
        guard model.store.database.preferences.clipboardEnabled, model.clipboard.accessBehavior != .alwaysAllow else {
            return "Background capture for Clipboard History"
        }
        return "In System Settings › Privacy & Security › Paste from Other Apps, set OpenRay to Always Allow."
    }

    @ViewBuilder private var clipboardStatus: some View {
        if !model.store.database.preferences.clipboardEnabled {
            StatusLabel(tone: .neutral, text: "Not in use")
        } else {
            switch model.clipboard.accessBehavior {
            case .alwaysAllow: StatusLabel(tone: .success, text: "Always allowed")
            case .alwaysDeny:
                HStack {
                    StatusLabel(tone: .danger, text: "Blocked")
                    Button("Fix…") { SystemSettingsLink.open(.pasteboard) }
                }
            default:
                HStack {
                    StatusLabel(tone: .warning, text: "Asks each time")
                    Button("Fix…") { SystemSettingsLink.open(.pasteboard) }
                        .help("In System Settings, choose Always Allow for OpenRay.")
                }
            }
        }
    }

    private func permission<Trailing: View>(
        kind: Kind, symbol: String?, title: String, detail: String, error: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                KindTile(kind: kind, symbol: symbol, size: 28)
                SettingRowLabel(title: title, detail: detail)
                Spacer()
                trailing()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(OR.Font.callout).foregroundStyle(OR.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, 2)
    }
}

enum SystemSettingsLink {
    enum Pane { case accessibility, pasteboard }

    static func open(_ pane: Pane) {
        let string =
            switch pane {
            case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .pasteboard: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
            }
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Library

private struct LibraryPane: View {
    let model: LauncherModel

    var body: some View {
        let database = model.store.database
        SettingsPaneScaffold(pane: .library) {
            Section("Contents") {
                LabeledContent("Notes", value: database.notes.count.formatted())
                LabeledContent("Snippets", value: database.snippets.count.formatted())
                LabeledContent("Quicklinks", value: database.quicklinks.count.formatted())
                LabeledContent("Favorites", value: database.favoriteIDs.count.formatted())
                LabeledContent("Clipboard entries", value: database.clipboard.count.formatted())
            }
            Section {
                if let url = model.store.fileURL {
                    LabeledContent {
                        HStack {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                            Button("Export…") { export(url) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                    } label: {
                        SettingRowLabel(title: "Location", detail: LauncherModel.shortenedPath(url.deletingLastPathComponent()))
                    }
                } else {
                    Label("This instance uses a temporary, in-memory library.", systemImage: "memorychip")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Data")
            } footer: {
                Text("library.json and the ClipboardImages folder are readable only by your account, but OpenRay doesn't encrypt them. Export saves library.json only, so back up both together.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func export(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenRay Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Exporting onto the live library would only replace it with itself.
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath()
        else { return }
        // An atomic write never leaves a half-written or deleted file at the destination.
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    let model: LauncherModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ORMark(size: 72).padding(.top, 8)
                    Text("OpenRay").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                    Text("Version \(AppInformation.version) · Apple silicon · macOS 27+").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("One quiet surface for everything you reach for. No account, analytics or cloud sync.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
            Section {
                Button("OpenRay Help") { model.presentHelp?() }
                // Links, so VoiceOver says they open a web page, styled like the Help button.
                Link("Read the Guide", destination: AppInformation.documentationURL).buttonStyle(.bordered)
                Link("Report an Issue", destination: AppInformation.supportURL).buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
    }
}

extension View {
    /// Settings tints with the accent text token so titles stay readable; switches use the fill
    /// token, like the launcher's switches and the design system's `.switch.on`.
    fileprivate func settingsSwitch() -> some View { tint(OR.Color.accentFill) }

    /// Pop-up values in the text color, as the design system's dropdowns are, not in Ray.
    fileprivate func neutralMenus() -> some View { tint(.primary) }
}

/// A symbol and a sentence, with the symbols in one fixed-width column so the text lines up.
private struct IconRow: View {
    var text: String
    var symbol: String

    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
    }
}
