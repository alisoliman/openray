import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class LauncherModel {
    enum Destination { case search, ai, settings, pomodoro, caffeinate }
    var destination: Destination = .search
    private(set) var section: LauncherSection = .home
    var query = "" { didSet { if query != oldValue { searchChanged() } } }
    var selectedID: String?
    var clipboardFilter: ClipboardFilter = .all { didSet { if clipboardFilter != oldValue { selectedID = nil } } }
    var editor: LibraryEditor?
    var showActions = false
    var message: String?
    var focusRequest = 0
    private(set) var shortcutError: String?
    private(set) var commandShortcutErrors: [String: String] = [:]
    private(set) var accessibilityAllowed = false
    private(set) var loginEnabled = false
    private(set) var loginNeedsApproval = false

    let store: LibraryStore
    let applications = ApplicationCatalog()
    let files = FileSearchService()
    private(set) var ai: AIChatModel
    let pomodoro: PomodoroService
    let caffeinate: CaffeinateService
    let windows = WindowManager()
    @ObservationIgnored let clipboard: ClipboardService
    @ObservationIgnored let snippets: SnippetExpander
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored weak var panel: LauncherPanelController?
    @ObservationIgnored var previousApplication: NSRunningApplication?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isRecordingShortcut = false
    @ObservationIgnored private var commandBindingEditorCount = 0
    @ObservationIgnored private let aiFactory: @MainActor () -> AIChatModel
    @ObservationIgnored private var aiSessions: [AIAction: AIChatModel]
    @ObservationIgnored private var aiReturnContext: (query: String, selectedID: String?)?

    init(
        store: LibraryStore = LibraryStore(), ai: AIChatModel = AIChatModel(),
        pasteboard: NSPasteboard = .general,
        caffeinate: CaffeinateService = CaffeinateService(),
        aiFactory: @escaping @MainActor () -> AIChatModel = { AIChatModel() }
    ) {
        self.store = store
        self.ai = ai
        self.caffeinate = caffeinate
        self.aiFactory = aiFactory
        aiSessions = [ai.action: ai]
        pomodoro = PomodoroService(store: store)
        clipboard = ClipboardService(store: store, pasteboard: pasteboard)
        snippets = SnippetExpander(store: store)
        store.commandBindingsDidChange = { [weak self] in self?.synchronizeCommandHotKeys() }
    }

    var results: [LauncherItem] {
        guard query.count <= 512 else { return [] }
        // Aliases are a single global namespace, independent of section, usage,
        // favorites, quicklink arguments and calculator interpretation.
        if let targetID = store.database.aliasTarget(for: query),
            let command = bindableCommands.first(where: { $0.id == targetID })
        {
            return [command]
        }
        var items: [LauncherItem] = []
        switch section {
        case .home:
            items = commandItems + applicationItems + quicklinkItems + snippetItems + noteItems + savedFileItems
            items += clipboardItems.filter { store.database.favoriteIDs.contains($0.id) }
            if query.count >= 2 { items += fileItems }
        case .applications: items = applicationItems
        case .files: items = fileItems
        case .clipboard:
            items = clipboardItems.filter { item in
                if case .clipboard(let entry) = item.action { return clipboardFilter.includes(entry) }
                return false
            }
        case .snippets: items = snippetItems
        case .quicklinks: items = quicklinkItems
        case .notes: items = noteItems
        case .calculator: items = []
        case .windows: items = windowItems
        }

        var seenIDs = Set<String>()
        items = items.filter { seenIDs.insert($0.id).inserted }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items = items.compactMap { item -> (LauncherItem, Int)? in
                if case .quicklink(let link, let argument) = item.action, link.argument(in: trimmed) != nil {
                    return (item, argument.isEmpty ? 1_000 : 1_100)
                }
                let titleScore = SearchMatcher.score(trimmed, in: item.title)
                let keywordScore = SearchMatcher.score(trimmed, in: item.keywords).map { $0 - 80 }
                guard let score = [titleScore, keywordScore].compactMap({ $0 }).max() else { return nil }
                let appBoost: Int
                if case .application = item.action { appBoost = 70 } else { appBoost = 0 }
                let commandBoost = item.isBuiltInCommand && titleScore == 1_000 ? 200 : 0
                return (item, score + appBoost + commandBoost + (store.database.favoriteIDs.contains(item.id) ? 15 : 0))
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                let comparison = $0.0.title.localizedStandardCompare($1.0.title)
                return comparison == .orderedSame ? $0.0.id < $1.0.id : comparison == .orderedAscending
            }.map(\.0)
        } else if section == .home {
            let usage = Dictionary(uniqueKeysWithValues: store.database.usage.map { ($0.id, $0.lastUsed) })
            items.sort { lhs, rhs in
                let leftFavorite = store.database.favoriteIDs.contains(lhs.id)
                let rightFavorite = store.database.favoriteIDs.contains(rhs.id)
                if leftFavorite != rightFavorite { return leftFavorite }
                let leftDate = usage[lhs.id] ?? .distantPast
                let rightDate = usage[rhs.id] ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                // Keep the curated command order ahead of the installed app catalog.
                return false
            }
            items = Array(items.prefix(14))
        }
        if section == .home || section == .calculator, let calculation = Calculator.evaluate(trimmed) {
            items.insert(
                LauncherItem(
                    id: "calculation", title: calculation.result,
                    subtitle: calculation.expression, symbol: "equal", tint: .green,
                    badge: "Calculator", action: .calculation(calculation)), at: 0)
        }
        return Array(items.prefix(section == .home ? 45 : 100))
    }

    var groups: [LauncherResultGroup] {
        let items = results
        guard query.isEmpty, section == .home else {
            return [LauncherResultGroup(title: query.isEmpty ? section.title : "Results", items: items)]
        }
        let favorites = items.filter { store.database.favoriteIDs.contains($0.id) }
        let recentIDs = Set(store.database.usage.map(\.id))
        let recent = items.filter { !store.database.favoriteIDs.contains($0.id) && recentIDs.contains($0.id) }
        let suggestions = items.filter { !store.database.favoriteIDs.contains($0.id) && !recentIDs.contains($0.id) }
        return [
            LauncherResultGroup(title: "Favorites", items: favorites),
            LauncherResultGroup(title: "Recently Used", items: recent),
            LauncherResultGroup(title: "Suggestions", items: suggestions),
        ].filter { !$0.items.isEmpty }
    }

    var orderedResults: [LauncherItem] { groups.flatMap(\.items) }
    var selectedItem: LauncherItem? { orderedResults.first(where: { $0.id == selectedID }) ?? orderedResults.first }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        pomodoro.startMonitoring()
        applyPreferences()
        await applications.refresh()
        synchronizeSelection()
    }

    func stop() {
        isStarted = false
        isRecordingShortcut = false
        hotKey.unregister()
        clipboard.stop()
        snippets.stop()
        files.stop()
        ai.cancel()
        pomodoro.stopMonitoring()
        caffeinate.shutdown()
    }

    func applyPreferences() {
        if isStarted {
            clipboard.configure()
            if clipboard.usesGeneralPasteboard { snippets.configure() } else { snippets.stop() }
        }
        refreshPermissions()
    }

    var bindableCommands: [LauncherItem] {
        let commands = commandItems
        return CuratedCommand.targetIDs.compactMap { id in commands.first { $0.id == id } }
    }

    func commandBinding(for targetID: String) -> CommandBinding {
        store.database.binding(for: targetID) ?? CommandBinding(targetID: targetID)
    }

    func bindingWarnings(for binding: CommandBinding) -> [String] {
        guard let shortcut = binding.shortcut else { return [] }
        var warnings = CommandShortcutPolicy.conflictWarnings(for: shortcut)
        if shortcut == store.database.preferences.hotKey.shortcut {
            warnings.append(
                "This shortcut opens the launcher. The command binding will stay inactive while the launcher uses it.")
        }
        for other in store.database.commandBindings
        where other.targetID != binding.targetID && other.shortcut == shortcut {
            let title = bindableCommands.first { $0.id == other.targetID }?.title ?? other.targetID
            warnings.append(
                "This shortcut is also assigned to \(title). Only the first saved assignment can be active; remove the other shortcut to use it here."
            )
        }
        return warnings
    }

    @discardableResult
    func saveCommandBinding(_ binding: CommandBinding, allowConflicts: Bool = false) -> Bool {
        do {
            try validateCommandBinding(binding)
            let warnings = bindingWarnings(for: binding)
            guard allowConflicts || warnings.isEmpty else {
                message = warnings.joined(separator: " ") + " Choose Save Anyway to keep this assignment."
                return false
            }
            guard store.saveCommandBinding(binding) else {
                message = store.errorMessage
                return false
            }
            message = commandShortcutErrors[binding.targetID] ?? "Command binding saved."
            synchronizeSelection()
            return true
        } catch {
            message = error.localizedDescription
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
            message = store.errorMessage
            return false
        }
        message = "Command binding removed."
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

    private func synchronizeCommandHotKeys() {
        guard isStarted, !isRecordingShortcut else { return }
        guard clipboard.usesGeneralPasteboard else {
            hotKey.unregister()
            shortcutError = nil
            commandShortcutErrors = [:]
            return
        }
        let issues = hotKey.synchronize(
            launcher: store.database.preferences.hotKey, bindings: store.database.commandBindings,
            onLauncher: { [weak self] in self?.panel?.toggle() },
            onCommand: { [weak self] in self?.performBoundCommand(targetID: $0) })
        shortcutError = issues.first { $0.targetID == GlobalHotKey.launcherTargetID }?.message
        commandShortcutErrors = Dictionary(
            issues.filter { $0.targetID != GlobalHotKey.launcherTargetID }.map { ($0.targetID, $0.message) },
            uniquingKeysWith: { first, second in first + " " + second })
    }

    /// Global invocations use the same dispatch as selected search results.
    /// Resolve again at delivery so a removed or disallowed target cannot run.
    func performBoundCommand(targetID: String) {
        guard !isRecordingShortcut, commandBindingEditorCount == 0,
            store.database.binding(for: targetID)?.shortcut != nil,
            let command = bindableCommands.first(where: { $0.id == targetID })
        else { return }
        guard editor == nil else {
            message = "Save or cancel the current editor before using a command shortcut."
            panel?.show()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        perform(command)
        switch command.action {
        case .window, .startCaffeinate, .stopCaffeinate, .toggleCaffeinate:
            if message != nil { panel?.show() }
        default:
            panel?.show()
        }
    }

    func refreshPermissions() {
        accessibilityAllowed = windows.hasPermission
        clipboard.refreshAccessStatus()
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        ai.refreshAvailability()
        synchronizeCommandHotKeys()
        if isStarted && clipboard.usesGeneralPasteboard { snippets.configure() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard clipboard.usesGeneralPasteboard else {
            message = "Launch at login is disabled for the isolated verification instance."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshPermissions()
        } catch { message = "Launch at login could not be changed: \(error.localizedDescription)" }
    }

    func navigate(to section: LauncherSection) {
        aiReturnContext = nil
        destination = .search
        self.section = section
        query = ""
        searchChanged()
        message = nil
        showActions = false
        synchronizeSelection()
        focusRequest += 1
    }

    func openAI(_ action: AIAction = .chat) {
        guard !hasActiveTextComposition else { return }
        aiReturnContext = nil
        activateAIAction(action)
        destination = .ai
        files.stop()
        showActions = false
    }

    /// Tab turns a search into an editable prompt; generating and importing text
    /// from another app remain explicit actions.
    @discardableResult
    func quickAI() -> Bool {
        guard destination == .search, section == .home, canSwitchAIWorkspace else { return false }
        let context = (query: query, selectedID: selectedID)
        let passage = isCommandQuery(query) ? "" : query
        guard activateAIAction(.chat) else { return true }
        aiReturnContext = context
        destination = .ai
        files.stop()
        if !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if ai.draft.isEmpty {
                ai.useText(passage)
            } else if ai.draft != passage {
                message = "Your previous draft is still here. Your search is preserved when you go back."
            }
        }
        return true
    }

    @discardableResult
    func cycleAIAction(_ delta: Int) -> Bool {
        guard destination == .ai, canSwitchAIWorkspace else { return false }
        let actions = AIAction.workspaceActions
        let index = actions.firstIndex(of: ai.action) ?? 0
        switchAIAction(actions[(index + delta % actions.count + actions.count) % actions.count])
        return true
    }

    func switchAIAction(_ action: AIAction) {
        guard destination == .ai, canSwitchAIWorkspace else { return }
        activateAIAction(action)
    }

    /// Borderless hosting views cannot reliably refresh SwiftUI keyboard
    /// equivalents when destinations change. Route workspace keys at the panel.
    @discardableResult
    func selectWorkspaceShortcut(_ index: Int) -> Bool {
        guard (0..<6).contains(index), canSwitchAIWorkspace else { return false }
        switch destination {
        case .search:
            if index == 5 {
                openAI()
            } else {
                navigate(to: [LauncherSection.home, .applications, .files, .clipboard, .notes][index])
            }
        case .ai:
            switchAIAction(AIAction.workspaceActions[index])
        case .settings, .pomodoro, .caffeinate:
            return false
        }
        return true
    }

    private var canSwitchAIWorkspace: Bool {
        !showActions && editor == nil && !isRecordingShortcut && commandBindingEditorCount == 0
            && !hasActiveTextComposition
    }

    private var hasActiveTextComposition: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    @discardableResult
    private func activateAIAction(_ action: AIAction) -> Bool {
        guard !ai.isGenerating || ai.action == action else {
            message = "Stop the current response or wait for it to finish before switching AI commands."
            return false
        }
        if ai.action != action {
            if let session = aiSessions[action] {
                ai = session
            } else {
                let draft = ai.draft
                let session = aiFactory()
                session.open(action)
                if session.draft.isEmpty, session.messages.isEmpty, !draft.isEmpty { session.useText(draft) }
                aiSessions[action] = session
                ai = session
            }
        }
        ai.open(action)
        message = nil
        focusRequest += 1
        return true
    }

    private func isCommandQuery(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if store.database.aliasTarget(for: query) != nil { return true }
        let commandNames = commandItems.map(\.title) + AIAction.workspaceActions.map(\.shortTitle) + ["AI", "Chat"]
        return commandNames.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    func openSettings() {
        aiReturnContext = nil
        destination = .settings
        files.stop()
        showActions = false
        refreshPermissions()
    }

    func openPomodoro(start: Bool = false) {
        aiReturnContext = nil
        destination = .pomodoro
        files.stop()
        showActions = false
        message = nil
        pomodoro.refresh()
        if start { pomodoro.start() }
    }

    func openCaffeinate() {
        aiReturnContext = nil
        destination = .caffeinate
        files.stop()
        showActions = false
        message = nil
        caffeinate.refresh()
    }

    func goBack() {
        if showActions {
            showActions = false
        } else if destination == .ai, let context = aiReturnContext {
            navigate(to: .home)
            query = context.query
            selectedID = context.selectedID
            synchronizeSelection()
        } else if destination != .search || section != .home {
            navigate(to: .home)
        } else if !query.isEmpty {
            query = ""
        } else {
            panel?.dismiss()
        }
    }

    func resumeSearch() {
        if destination == .search, section == .home || section == .files {
            files.search(query, showRecent: section == .files)
        }
    }

    func synchronizeSelection() {
        let items = orderedResults
        if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
    }

    func moveSelection(_ offset: Int) {
        guard !showActions else { return }
        let items = orderedResults
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = items[(index + offset + items.count) % items.count].id
    }

    func performSelected() {
        guard !showActions else { return }
        if let selectedItem { perform(selectedItem) }
    }

    func perform(_ item: LauncherItem) {
        showActions = false
        message = nil
        switch item.action {
        case .application(let app):
            Task {
                do {
                    _ = try await NSWorkspace.shared.openApplication(
                        at: app.url, configuration: NSWorkspace.OpenConfiguration())
                    store.recordUse(of: item.id)
                    panel?.dismiss(restoreFocus: false)
                } catch { message = "Could not open \(app.name): \(error.localizedDescription)" }
            }
        case .file(let url): open(url, itemID: item.id)
        case .section(let section):
            store.recordUse(of: item.id)
            navigate(to: section)
        case .ai(let action):
            store.recordUse(of: item.id)
            openAI(action)
        case .settings: openSettings()
        case .pomodoro:
            store.recordUse(of: item.id)
            openPomodoro()
        case .startPomodoro:
            openPomodoro(start: true)
            store.recordUse(of: item.id)
        case .caffeinate:
            openCaffeinate()
            store.recordUse(of: item.id)
        case .startCaffeinate:
            finishCaffeinateCommand(item, succeeded: caffeinate.start())
        case .stopCaffeinate:
            finishCaffeinateCommand(item, succeeded: caffeinate.stop())
        case .toggleCaffeinate:
            finishCaffeinateCommand(item, succeeded: caffeinate.toggle())
        case .quicklink(let link, let argument):
            if link.needsQuery && argument.isEmpty {
                editor = .quicklinkQuery(link, "")
            } else {
                openQuicklink(link, query: argument)
            }
        case .clipboard(let entry):
            copy(entry)
            store.recordUse(of: item.id)
        case .snippet(let snippet):
            copy(snippet.expanded())
            store.recordUse(of: item.id)
        case .calculation(let calculation): copy(calculation.result)
        case .note(let note):
            editor = .note(note)
            store.recordUse(of: item.id)
        case .window(let layout):
            do {
                try windows.arrange(layout, application: previousApplication)
                store.recordUse(of: item.id)
                panel?.dismiss(restoreFocus: false)
            } catch { message = error.localizedDescription }
        }
    }

    private func finishCaffeinateCommand(_ item: LauncherItem, succeeded: Bool) {
        if succeeded {
            store.recordUse(of: item.id)
            panel?.dismiss()
        } else {
            aiReturnContext = nil
            destination = .caffeinate
            files.stop()
            message = caffeinate.errorMessage
        }
    }

    func openQuicklink(_ link: Quicklink, query: String) {
        do { open(try link.resolvedURL(query: query), itemID: "quicklink.\(link.id)") } catch {
            message = error.localizedDescription
        }
    }

    func copy(_ text: String) {
        message = clipboard.copy(text) ? "Copied to clipboard" : "Could not write to the clipboard. Try again."
    }

    func copy(_ entry: ClipboardEntry) {
        message =
            clipboard.copy(entry)
            ? "Copied to clipboard" : (clipboard.contentMessage ?? "Could not write to the clipboard. Try again.")
    }

    func pasteSelected() {
        guard let item = selectedItem, item.supportsPaste else { return }
        if case .clipboard(let entry) = item.action {
            finishPaste(copied: clipboard.copy(entry))
        } else if let text = item.copyText {
            paste(text)
        }
    }

    func paste(_ text: String) {
        finishPaste(copied: clipboard.copy(text))
    }

    private func finishPaste(copied: Bool) {
        guard copied else {
            message = clipboard.contentMessage ?? "Could not copy the content."
            return
        }
        guard clipboard.usesGeneralPasteboard else {
            message = "Copied to the isolated verification pasteboard. Cross-app paste is disabled in this mode."
            return
        }
        guard let target = previousApplication, !target.isTerminated, windows.hasPermission else {
            message = "Copied. Press ⌘V in your app, or enable Accessibility in Settings for direct paste."
            return
        }
        let changeCount = clipboard.changeCount
        panel?.dismiss(restoreFocus: false)
        Task {
            do { try await SyntheticInput.paste(into: target, expectedChangeCount: changeCount) } catch {
                message = error.localizedDescription
                panel?.show()
            }
        }
    }

    func useSelectionForAI() {
        do { ai.useText(try windows.selectedText(in: previousApplication)) } catch {
            message = error.localizedDescription
        }
    }

    func editSelected() {
        guard let item = selectedItem else { return }
        showActions = false
        switch item.action {
        case .quicklink(let link, _): editor = .quicklink(link)
        case .snippet(let snippet): editor = .snippet(snippet)
        case .note(let note): editor = .note(note)
        default: break
        }
    }

    func delete(_ item: LauncherItem) {
        store.update { database in
            switch item.action {
            case .quicklink(let link, _): database.quicklinks.removeAll { $0.id == link.id }
            case .snippet(let snippet): database.snippets.removeAll { $0.id == snippet.id }
            case .note(let note): database.notes.removeAll { $0.id == note.id }
            case .clipboard(let entry): database.clipboard.removeAll { $0.id == entry.id }
            default: return
            }
            database.favoriteIDs.remove(item.id)
            database.usage.removeAll { $0.id == item.id }
        }
        synchronizeSelection()
    }

    func createItem() {
        switch section {
        case .snippets: editor = .snippet(Snippet(name: "", keyword: "", content: ""))
        case .quicklinks: editor = .quicklink(Quicklink(name: "", template: "https://", keyword: ""))
        case .notes: editor = .note(QuickNote(title: "", content: ""))
        default: break
        }
    }

    private func open(_ url: URL, itemID: String) {
        if NSWorkspace.shared.open(url) {
            store.recordUse(of: itemID)
            panel?.dismiss(restoreFocus: false)
        } else {
            message =
                "macOS could not open \(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)."
        }
    }

    private func searchChanged() {
        selectedID = nil
        message = nil
        guard query.count <= 512 else {
            files.stop()
            message = "Keep search queries under 512 characters. For a longer passage, open Ask AI."
            return
        }
        if section == .home || section == .files {
            files.search(query, showRecent: section == .files)
        } else {
            files.stop()
        }
    }

    private var applicationItems: [LauncherItem] {
        applications.applications.map { app in
            LauncherItem(
                id: app.id, title: app.name, subtitle: app.url.deletingLastPathComponent().path,
                symbol: "app", badge: "Application", keywords: app.bundleIdentifier ?? "",
                iconURL: app.url, action: .application(app))
        }
    }

    private var fileItems: [LauncherItem] {
        files.results.map { file in
            LauncherItem(
                id: file.id, title: file.name, subtitle: file.url.deletingLastPathComponent().path,
                symbol: "doc", badge: "File", iconURL: file.url, action: .file(file.url))
        }
    }

    private var savedFileItems: [LauncherItem] {
        let ids = store.database.favoriteIDs.union(store.database.usage.map(\.id)).sorted()
        return ids.filter { $0.hasPrefix("file./") }.map { id in
            let url = URL(fileURLWithPath: String(id.dropFirst("file.".count)))
            return LauncherItem(
                id: id, title: url.lastPathComponent, subtitle: url.deletingLastPathComponent().path,
                symbol: "doc", badge: "File", iconURL: url, action: .file(url))
        }
    }

    private var clipboardItems: [LauncherItem] {
        store.database.clipboard.map { entry in
            LauncherItem(
                id: "clipboard.\(entry.id)", title: entry.title, subtitle: entry.sourceName,
                symbol: entry.symbol, tint: .orange, badge: entry.kindTitle, keywords: entry.searchableText,
                clipboardImage: entry.image.flatMap { store.imageResource(for: $0) },
                action: .clipboard(entry))
        }
    }

    private var quicklinkItems: [LauncherItem] {
        store.database.quicklinks.map { link in
            let argument = link.argument(in: query) ?? ""
            return LauncherItem(
                id: "quicklink.\(link.id)", title: link.name,
                subtitle: argument.isEmpty ? link.template : "Search for “\(argument)”",
                symbol: "link", tint: .blue, badge: "Quicklink", keywords: link.keyword,
                action: .quicklink(link, argument))
        }
    }

    private var snippetItems: [LauncherItem] {
        store.database.snippets.map { snippet in
            LauncherItem(
                id: "snippet.\(snippet.id)", title: snippet.name,
                subtitle: snippet.keyword.isEmpty ? String(snippet.content.prefix(90)) : snippet.keyword,
                symbol: "text.quote", tint: .orange, badge: "Snippet",
                keywords: snippet.keyword + " " + snippet.content, action: .snippet(snippet))
        }
    }

    private var noteItems: [LauncherItem] {
        store.database.notes.sorted { $0.modifiedAt > $1.modifiedAt }.map { note in
            LauncherItem(
                id: "note.\(note.id)", title: note.title, subtitle: String(note.content.prefix(90)),
                symbol: "note.text", tint: .green, badge: "Note", keywords: note.content, action: .note(note))
        }
    }

    private var windowItems: [LauncherItem] {
        WindowLayout.allCases.map { layout in
            LauncherItem(
                id: "window.\(layout.id)", title: layout.title, subtitle: "Arrange the previously focused window",
                symbol: layout.symbol, tint: .purple, badge: "Window", keywords: "window resize move tile",
                action: .window(layout))
        }
    }

    private var commandItems: [LauncherItem] {
        var commands = [
            LauncherItem(
                id: "ai.chat", title: "Ask AI", subtitle: "Your private, on-device assistant",
                symbol: "sparkles", tint: .purple, badge: "Apple Intelligence", keywords: "chat assistant write",
                action: .ai(.chat))
        ]
        commands += LauncherSection.allCases.filter { $0 != .home }.map { section in
            LauncherItem(
                id: "section.\(section.id)", title: section.title,
                subtitle: section.placeholder.replacingOccurrences(of: "…", with: ""),
                symbol: section.symbol, tint: section == .clipboard ? .orange : .blue,
                badge: "Command", keywords: "search " + section.title, action: .section(section))
        }
        commands += [
            LauncherItem(
                id: "pomodoro.open", title: "Pomodoro", subtitle: "Track your focus sessions and breaks",
                symbol: "timer", tint: .coral, badge: "Command", keywords: "focus timer productivity break history",
                action: .pomodoro),
            LauncherItem(
                id: "pomodoro.start", title: "Start Pomodoro", subtitle: "Start or resume your focus timer",
                symbol: "play.circle", tint: .coral, badge: "Command", keywords: "focus timer begin resume break",
                action: .startPomodoro),
            LauncherItem(
                id: "caffeinate.open", title: "Caffeinate", subtitle: caffeinate.statusText,
                symbol: caffeinate.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", tint: .orange,
                badge: caffeinate.isActive ? "Active" : "Command",
                keywords: "coffee caffeine awake sleep duration timer status",
                action: .caffeinate),
            LauncherItem(
                id: "caffeinate.start", title: "Start Caffeinate",
                subtitle: "Keep your Mac and display awake indefinitely",
                symbol: "cup.and.saucer.fill", tint: .orange, badge: "Command",
                keywords: "coffee caffeine awake prevent sleep on",
                action: .startCaffeinate),
            LauncherItem(
                id: "caffeinate.stop", title: "Stop Caffeinate",
                subtitle: "Let your Mac follow its normal sleep settings",
                symbol: "moon.zzz", tint: .orange, badge: "Command", keywords: "coffee caffeine decaffeinate sleep off",
                action: .stopCaffeinate),
            LauncherItem(
                id: "caffeinate.toggle", title: "Toggle Caffeinate",
                subtitle: caffeinate.isActive ? "Stop keeping your Mac awake" : "Keep your Mac awake indefinitely",
                symbol: "power", tint: .orange, badge: caffeinate.isActive ? "Active" : "Command",
                keywords: "coffee caffeine awake sleep switch on off", action: .toggleCaffeinate),
        ]
        commands += AIAction.allCases.filter { $0 != .chat }.map { action in
            LauncherItem(
                id: "ai.\(action.id)", title: action.title, subtitle: action.subtitle,
                symbol: action.symbol, tint: .purple, badge: "AI Command", keywords: "AI writing text",
                action: .ai(action))
        }
        commands += windowItems
        commands.append(
            LauncherItem(
                id: "settings", title: "Settings", subtitle: "Make OpenRay your own",
                symbol: "gearshape", badge: "Command", keywords: "openray settings preferences permissions shortcut",
                action: .settings))
        return commands
    }
}
