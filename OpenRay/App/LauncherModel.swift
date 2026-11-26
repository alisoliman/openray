import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class LauncherModel {
    enum Destination { case search, ai }
    enum OnboardingStep: Int, CaseIterable { case shortcut, features, keys }

    var destination: Destination = .search
    private(set) var section: LauncherSection = .home
    var query = "" { didSet { if query != oldValue { searchChanged() } } }
    var selectedID: String?
    var clipboardFilter: ClipboardFilter = .all {
        didSet {
            guard clipboardFilter != oldValue else { return }
            selectedID = nil
            selectionWillChange()
        }
    }
    var fileScope: FileSearchScope = .home {
        didSet {
            guard fileScope != oldValue else { return }
            selectedID = nil
            selectionWillChange()
            // A hidden panel searches again in resumeSearch() when it shows.
            if section == .files, panel?.isVisible == true, destination == .search, argumentLink == nil {
                files.search(query, showRecent: true, scope: fileScope)
            }
            store.update { $0.preferences.fileSearchScope = fileScope }
        }
    }
    var editor: LibraryEditor? { didSet { editorDidChange(from: oldValue) } }
    private(set) var draft: EditorDraft?
    /// The quicklink whose search term is being typed, shown as an argument token.
    private(set) var argumentLink: Quicklink?
    var showActions = false { didSet { if showActions != oldValue { actionsDidToggle() } } }
    var showShortcuts = false
    /// The writing command's attached text, shown in full over the AI view.
    var showsAttachmentPreview = false
    var feedback: Feedback? { didSet { scheduleFeedbackExpiry() } }
    var confirmation: ActionConfirmation?
    var focusRequest = 0
    /// Set when a remembered query returns; the field selects it so the next keystroke replaces it.
    var selectsQueryOnFocus = false
    private(set) var onboarding: OnboardingStep?
    var onboardingHotKeyPressed = false
    /// Bumped on each show to play the appear animation.
    private(set) var presentation = 0
    /// False while hidden, so the panel can animate in (0.98 → 1) on show.
    var isPresented = true
    /// The panel's current size, reported by the view for hit testing.
    @ObservationIgnored var panelSize = CGSize(width: OR.Metric.panelWidth, height: OR.Detent.list)
    /// Why the registered launcher shortcut isn't the saved one, or isn't working.
    var shortcutError: String?
    /// Why the last launcher shortcut choice was refused. The saved shortcut still works.
    var launcherHotKeyRefusal: String?
    var commandShortcutErrors: [String: String] = [:]
    private(set) var accessibilityAllowed = false
    private(set) var loginEnabled = false
    private(set) var loginNeedsApproval = false
    /// Why the last Open at Login change failed, shown under the setting.
    private(set) var loginError: String?
    private(set) var targetWindowTitle: String?
    /// The window layouts apply to, when one was chosen from the target chip.
    /// Otherwise layouts use the focused window of the previous app.
    var targetWindow: WindowManager.TargetWindow?

    struct ClipboardOptInChoices {
        var images = true
        var files = false
        var days = 7
        var limit = 100
    }
    /// Choices on the clipboard opt-in screen, made before anything is stored.
    var clipboardOptIn = ClipboardOptInChoices()

    // Action panel state, snapshotted when it opens so ↩ runs what was shown.
    var actionEntries: [ActionEntry] = []
    var actionFilter = "" { didSet { actionSelection = 0 } }
    var actionSelection = 0

    let store: LibraryStore
    /// The registered command providers. Rows with `.provided` actions dispatch through it.
    let registry: CommandRegistry
    /// Rows from providers' live searches, by provider id, for the current query and scope.
    private(set) var providedLiveItems: [String: [LauncherItem]] = [:]
    /// Providers whose live search for the current query hasn't answered yet.
    private(set) var pendingLiveProviderIDs: Set<String> = []
    /// True while a provider's live search for the current query is running.
    var isLoadingProvidedItems: Bool { !pendingLiveProviderIDs.isEmpty }
    @ObservationIgnored private var providedLiveTasks: [Task<Void, Never>] = []
    /// Bumped whenever live searches restart or stop, so a late answer for an earlier query is dropped.
    @ObservationIgnored private var liveGeneration = 0
    let applications = ApplicationCatalog()
    let files = FileSearchService()
    let ai: AIChatModel
    let windows = WindowManager()
    @ObservationIgnored let clipboard: ClipboardService
    @ObservationIgnored let snippets: SnippetExpander
    // Slice 2: quicklinks open through the guarded opener, which is inert in tests and verification.
    @ObservationIgnored var quicklinkOpener: any QuicklinkOpening = QuicklinkOpeners.makeDefault()
    @ObservationIgnored var applicationResolver: any ApplicationResolving = WorkspaceApplicationResolver()
    /// Forces what ↩ does on clipboard entries and snippets; see `contentPrimaryAction`.
    @ObservationIgnored var primaryActionOverride: ContentPrimaryAction?
    @ObservationIgnored let hotKey: GlobalHotKey
    /// A hotkey registry passed in by a test, backed by a fake. It may register while the
    /// pasteboard is isolated; the real Carbon one never does.
    @ObservationIgnored let usesInjectedHotKey: Bool
    @ObservationIgnored weak var panel: LauncherPanelController?
    @ObservationIgnored var previousApplication: NSRunningApplication? {
        didSet {
            // A new source app means a new context; a chosen window doesn't carry over.
            targetWindow = nil
            if previousApplication != oldValue { previousApplicationName = previousApplication?.localizedName }
        }
    }
    private(set) var previousApplicationName: String?
    /// Opens Settings at a pane and, optionally, at a command's row.
    @ObservationIgnored var presentSettings: ((SettingsPane?, String?) -> Void)?
    @ObservationIgnored var presentHelp: (() -> Void)?
    @ObservationIgnored var isStarted = false
    @ObservationIgnored var isRecordingShortcut = false
    @ObservationIgnored var commandBindingEditorCount = 0
    @ObservationIgnored private var scopeReturnQuery: String?
    /// Set when ↑/↓/←/→ move the selection, cleared by a new query. See `synchronizeSelection`.
    @ObservationIgnored private(set) var selectionMovedByHand = false
    /// Counts query changes, so a provider can tell one search from the next even when the text
    /// is the same.
    @ObservationIgnored private(set) var searchGeneration = 0
    @ObservationIgnored private var aiReturn: (section: LauncherSection, query: String)?
    @ObservationIgnored private var lastHiddenAt: Date?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    @ObservationIgnored private var browserName: String?
    /// Stands in for the Accessibility read of the selected text. Tests set it.
    @ObservationIgnored var selectionReader: (() throws -> String)?

    init(
        store: LibraryStore = LibraryStore(), ai: AIChatModel = AIChatModel(), pasteboard: NSPasteboard = .general,
        registry: CommandRegistry = CommandRegistry(), hotKey: GlobalHotKey? = nil
    ) {
        self.store = store
        self.registry = registry
        self.hotKey = hotKey ?? GlobalHotKey()
        usesInjectedHotKey = hotKey != nil
        self.ai = ai
        clipboard = ClipboardService(store: store, pasteboard: pasteboard)
        snippets = SnippetExpander(store: store)
        // {clipboard} in expanded snippets reads through the service, which skips excluded copies.
        snippets.clipboardReader = { [clipboard] in clipboard.placeholderText() }
        fileScope = store.database.preferences.fileSearchScope ?? .home
        store.commandBindingsDidChange = { [weak self] in self?.synchronizeCommandHotKeys() }
    }

    /// Compatibility shim: the last error or notice, as text.
    var message: String? {
        get { feedback?.text }
        set { feedback = newValue.map { .error($0) } }
    }

    // MARK: - Results

    var results: [LauncherItem] {
        guard query.count <= 512 else { return [] }
        if let link = argumentLink { return argumentItems(for: link) }
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
            let clipboardInSearch = store.database.preferences.showsClipboardInRootSearch
            items += clipboardItems.filter { clipboardInSearch || store.database.favoriteIDs.contains($0.id) }
            items += registry.rootItems(for: query.trimmingCharacters(in: .whitespacesAndNewlines), in: self)
            if query.count >= 2 { items += fileItems }
            items += providedLiveItemsInOrder
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
        case .provided(let scope):
            items = registry.scopeItems(scope, query: query.trimmingCharacters(in: .whitespacesAndNewlines), in: self)
            items += providedLiveItemsInOrder
        }

        var seenIDs = Set<String>()
        items = items.filter { seenIDs.insert($0.id).inserted }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, section.providedScope?.ranksItems ?? true {
            let now = Date.now
            let favorites = store.database.favoriteIDs
            let usage = Dictionary(store.database.usage.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            items = items.compactMap { item -> (LauncherItem, Int)? in
                if case .quicklink(let link, let argument) = item.action, link.argument(in: trimmed) != nil {
                    return (item, argument.isEmpty ? 1_000 : 1_100)
                }
                // Provided rows that answer the query, such as a conversion, skip the matcher.
                if case .provided(let ref) = item.action, let rank = ref.rank { return (item, rank) }
                let titleScore = SearchMatcher.score(trimmed, in: item.title)
                // Keywords match by word, prefix or substring only; scattered letters are noise there.
                let keywordScore = SearchMatcher.score(trimmed, in: item.keywords).flatMap { $0 >= 450 ? $0 - 80 : nil }
                guard let score = [titleScore, keywordScore].compactMap({ $0 }).max() else { return nil }
                let appBoost: Int
                if case .application = item.action { appBoost = 70 } else { appBoost = 0 }
                let commandBoost = item.isBuiltInCommand && titleScore == 1_000 ? 200 : 0
                let favoriteBoost = favorites.contains(item.id) ? 15 : 0
                // Frequent and recent use breaks near-ties (at most 55), never an exact match.
                let usageBoost =
                    usage[item.id].map { record -> Int in
                        let age = now.timeIntervalSince(record.lastUsed)
                        return min(record.count, 10) * 3 + (age < 86_400 ? 25 : age < 604_800 ? 12 : 0)
                    } ?? 0
                return (item, score + appBoost + commandBoost + favoriteBoost + usageBoost)
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                let comparison = $0.0.title.localizedStandardCompare($1.0.title)
                return comparison == .orderedSame ? $0.0.id < $1.0.id : comparison == .orderedAscending
            }.map(\.0)
        }
        if section == .home || section == .calculator, let answer = calculatorAnswerItem(for: trimmed) {
            // First in the list so the cap never drops it; searchGroups decides where it shows.
            items.insert(answer, at: 0)
        }
        let shown = Self.capped(items, in: section)
        return trimmed.isEmpty ? shown : shown.map { Self.explainingMatch($0, query: trimmed) }
    }

    /// The calculator's answer for a query, as a row. With the calculator provider registered
    /// it's the provider's row, using its settings (currency rates, rem size), and ↩, ⌘↩, ⌘K
    /// and history go through it; otherwise a plain `.calculation` row. A words-only answer
    /// ("time", "today") gets `CalculatorProvider.wordAnswerID`, so root search ranks it as an
    /// ordinary row instead of putting it first.
    private func calculatorAnswerItem(for query: String) -> LauncherItem? {
        let provider = registry.provider(id: CalculatorProvider.registration.id) as? CalculatorProvider
        // Only root search has results that arrive later.
        let pending = section == .home && CalculatorProvider.isSearchPending(self)
        if let provider {
            return provider.answer(for: query, in: self).map {
                CalculatorProvider.answerItem(for: $0, searchPending: pending)
            }
        }
        guard let calculation = Calculator.evaluate(query) else { return nil }
        let wordID = pending ? CalculatorProvider.pendingWordAnswerID : CalculatorProvider.wordAnswerID
        return LauncherItem(
            id: calculation.isAmbiguous ? wordID : CalculatorProvider.answerID,
            title: calculation.result, subtitle: calculation.expression, symbol: "equal", kind: .calculator,
            badge: "Calculator", action: .calculation(calculation))
    }

    /// Home keeps up to 45 instant rows and 20 Spotlight rows, capped separately
    /// so a flood of late files can never push out the Top Hit. Scopes show 100.
    nonisolated static func capped(_ items: [LauncherItem], in section: LauncherSection) -> [LauncherItem] {
        guard section == .home else { return Array(items.prefix(100)) }
        let instant = items.filter { !$0.isLiveResult }.prefix(45)
        let live = items.filter(\.isLiveResult).prefix(20)
        return Array(instant) + Array(live)
    }

    /// True when the query is empty or only whitespace.
    var isQueryBlank: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Bar mode shows only the field while Home is idle. Anything that needs to
    /// be seen, such as a toast, an error or a delete prompt, expands it.
    var isCollapsedToBar: Bool {
        store.database.preferences.usesBarMode && destination == .search && editor == nil && onboarding == nil
            && section == .home && isQueryBlank && argumentLink == nil && !showActions && feedback == nil
            && confirmation == nil && store.errorMessage == nil && shortcutError == nil
    }

    var groups: [LauncherResultGroup] {
        if let link = argumentLink {
            let items = argumentItems(for: link)
            return [
                LauncherResultGroup(id: "argument", title: nil, items: Array(items.prefix(1))),
                LauncherResultGroup(id: "elsewhere", title: "Same search elsewhere", items: Array(items.dropFirst())),
            ].filter { !$0.items.isEmpty }
        }
        // An empty Home shows favorites and recents, so it never computes results.
        switch section {
        case .home where isQueryBlank: return homeGroups
        case .home: return searchGroups(results)
        case .clipboard: return clipboardGroups(results)
        case .windows: return [LauncherResultGroup(id: "windows", title: nil, style: .grid, items: results)]
        case .calculator:
            let items = results
            return items.isEmpty ? [] : [LauncherResultGroup(id: "calculator", title: nil, style: .calculator, items: items)]
        case .files:
            return [
                LauncherResultGroup(
                    id: "files", title: isQueryBlank ? "Recent in \(fileScope.title)" : nil, items: results)
            ].filter { !$0.items.isEmpty }
        case .provided(let scope):
            return registry.scopeGroups(scope, items: results, in: self)
        default:
            return [LauncherResultGroup(id: section.rawValue, title: nil, items: results)].filter { !$0.items.isEmpty }
        }
    }

    var orderedResults: [LauncherItem] { groups.flatMap(\.items) }
    var selectedItem: LauncherItem? {
        let ordered = orderedResults
        if let selected = ordered.first(where: { $0.id == selectedID }) { return selected }
        let fallback = ProvisionalSelection.defaultID(in: ordered)
        return ordered.first { $0.id == fallback }
    }

    /// Up to sixteen favorites (⌘1–⌘8 open the first eight) and four recents.
    var favoriteItems: [LauncherItem] {
        let index = Dictionary(
            (commandItems + applicationItems + quicklinkItems + snippetItems + noteItems + savedFileItems
                + clipboardItems).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.database.orderedFavoriteIDs.compactMap { index[$0] ?? registry.item(withID: $0, in: self) }
            .prefix(16).map { $0 }
    }

    private var homeGroups: [LauncherResultGroup] {
        let favorites = favoriteItems
        let favoriteIDs = Set(favorites.map(\.id))
        let index = Dictionary(
            (commandItems + applicationItems + quicklinkItems + snippetItems + noteItems + savedFileItems).map {
                ($0.id, $0)
            }, uniquingKeysWith: { first, _ in first })
        // Clipboard entries stay out of Everything unless they are favorites.
        let recent = store.database.usage.sorted { $0.lastUsed > $1.lastUsed }
            .filter { !favoriteIDs.contains($0.id) && !$0.id.hasPrefix("clipboard.") }
            .compactMap { index[$0.id] ?? registry.item(withID: $0.id, in: self) }.prefix(4)
        return [
            LauncherResultGroup(
                id: "favorites", title: "Favorites", trailing: favorites.count > 1 ? "⌘1 – ⌘\(min(8, favorites.count))" : nil,
                style: .favorites, items: favorites),
            LauncherResultGroup(id: "recent", title: "Recent", items: Array(recent)),
        ].filter { !$0.items.isEmpty }
    }

    /// Top Hit comes from instant sources only, so late Spotlight results never
    /// move the selection. Groups have a fixed order and fallbacks come last.
    private func searchGroups(_ items: [LauncherItem]) -> [LauncherResultGroup] {
        var groups: [LauncherResultGroup] = []
        var instant = items.filter { !$0.isLiveResult }
        // A words-only calculator answer never takes the Top Hit; it follows Files and live rows.
        let wordAnswer = instant.first { CalculatorProvider.isWordAnswer($0.id) }
        instant.removeAll { CalculatorProvider.isWordAnswer($0.id) }
        if let calculation = instant.first(where: { $0.id == CalculatorProvider.answerID }) {
            groups.append(LauncherResultGroup(id: "calculator", title: "Calculator", style: .calculator, items: [calculation]))
            instant.removeAll { $0.id == CalculatorProvider.answerID }
        } else if let top = instant.first {
            groups.append(LauncherResultGroup(id: "top", title: "Top Hit", items: [top]))
            instant.removeFirst()
        }
        func isCommand(_ item: LauncherItem) -> Bool { item.isBuiltInCommand }
        func isApp(_ item: LauncherItem) -> Bool { if case .application = item.action { true } else { false } }
        groups.append(LauncherResultGroup(id: "commands", title: "Commands", items: instant.filter(isCommand)))
        groups.append(LauncherResultGroup(id: "apps", title: "Applications", items: instant.filter(isApp)))
        groups.append(
            LauncherResultGroup(
                id: "library", title: "Library", items: instant.filter { !isCommand($0) && !isApp($0) }))
        let live = items.filter { item in
            if case .provided = item.action { return false }
            return item.isLiveResult
        }
        let searching = files.isSearching && query.count >= 2
        // Files appears with its first rows. Until then the field's spinner and the bar's
        // “Searching…” show progress, and an empty header can't vanish and shift the rows below.
        if !live.isEmpty {
            groups.append(
                LauncherResultGroup(
                    id: "files", title: "Files", trailing: searching ? "Searching \(FileSearchScope.home.title.lowercased()) folder" : nil,
                    isLoading: searching, items: live))
        }
        // Each provider's live rows follow Files under the provider's own title.
        for provider in registry.providers {
            let rows = items.filter { item in
                if case .provided(let ref) = item.action { return item.isLiveResult && ref.provider == provider.id }
                return false
            }
            groups.append(LauncherResultGroup(id: "live.\(provider.id)", title: provider.liveGroupTitle, items: rows))
        }
        if let wordAnswer {
            groups.append(LauncherResultGroup(id: "calculator", title: "Calculator", items: [wordAnswer]))
        }
        groups.append(
            LauncherResultGroup(
                id: "fallbacks", title: "Use “\(query.trimmingCharacters(in: .whitespaces).truncatedForFeedback)” with…",
                style: .fallback, items: fallbackItems))
        return groups.filter { !$0.items.isEmpty || $0.isLoading }
    }

    private var fallbackItems: [LauncherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var items = [
            LauncherItem(
                id: "fallback.ai", title: "Ask AI", subtitle: ai.availability.isAvailable ? "" : "Not available yet",
                symbol: "sparkles", kind: .ai, badge: "Ask AI", action: .askAI(trimmed))
        ]
        if let web = webSearchLink {
            items.append(
                LauncherItem(
                    id: "fallback.web", title: web.name, subtitle: Self.siteName(for: web),
                    symbol: "globe", kind: .quicklink, badge: "Quicklink", action: .quicklink(web, trimmed)))
        }
        return items + registry.fallbackItems(for: trimmed, in: self)
    }

    private var webSearchLink: Quicklink? {
        let links = store.database.quicklinks.filter(\.needsQuery)
        return links.first { $0.keyword.lowercased() == "web" } ?? links.first
    }

    private func clipboardGroups(_ items: [LauncherItem]) -> [LauncherResultGroup] {
        func entry(_ item: LauncherItem) -> ClipboardEntry? {
            if case .clipboard(let entry) = item.action { entry } else { nil }
        }
        var groups: [LauncherResultGroup] = []
        let pinned = items.filter { entry($0)?.isPinned == true }
        if !pinned.isEmpty { groups.append(LauncherResultGroup(id: "pinned", title: "Pinned", items: pinned)) }
        let rest = items.filter { entry($0)?.isPinned != true }
        guard !rest.isEmpty else { return groups }
        // Search results keep their score order, so the best match stays first and selected.
        guard isQueryBlank else {
            groups.append(LauncherResultGroup(id: "clipboard.results", title: nil, items: rest))
            return groups
        }
        // History is newest first: one group per day, so headers never repeat.
        let calendar = Calendar.current
        var days: [Date] = []
        var itemsByDay: [Date: [LauncherItem]] = [:]
        for item in rest {
            let day = calendar.startOfDay(for: entry(item)?.copiedAt ?? .now)
            if itemsByDay[day] == nil { days.append(day) }
            itemsByDay[day, default: []].append(item)
        }
        for day in days {
            groups.append(
                LauncherResultGroup(
                    id: "day.\(day.timeIntervalSinceReferenceDate)", title: Self.dayTitle(for: day, calendar: calendar),
                    items: itemsByDay[day] ?? []))
        }
        return groups
    }

    nonisolated static func dayTitle(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide))
    }

    private func argumentItems(for link: Quicklink) -> [LauncherItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = Self.siteName(for: link)
        let resolved = (try? link.resolvedURL(query: term.isEmpty ? "…" : term))?.absoluteString ?? link.template
        let primary = LauncherItem(
            id: "argument.\(link.id)",
            title: term.isEmpty ? "Search \(site)" : "Search \(site) for “\(term)”",
            // Percent-escapes stay visible, so you can see how the term is encoded.
            subtitle: term.isEmpty ? "Type what to search for" : Self.displayURL(resolved, decoding: false),
            symbol: "globe", kind: .quicklink, badge: defaultBrowserName, action: .quicklink(link, term))
        let others = store.database.quicklinks.filter { $0.needsQuery && $0.id != link.id }.map { other in
            LauncherItem(
                id: "argument.\(other.id)", title: other.name,
                subtitle: Self.displayURL(other.template.replacingOccurrences(of: "{query}", with: "…")),
                symbol: "link", kind: .quicklink, badge: "Quicklink", keywords: other.keyword,
                action: .quicklink(other, term))
        }
        return [primary] + others
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true
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
        cancelProvidedLiveItems()
        ai.cancel()
    }

    func applyPreferences() {
        if isStarted {
            clipboard.configure()
            if clipboard.usesGeneralPasteboard { snippets.configure() } else { snippets.stop() }
        }
        refreshPermissions()
    }

    /// Called just before the panel appears.
    func panelWillShow() {
        presentation += 1
        let remembered =
            store.database.preferences.remembersLastQuery
            && (lastHiddenAt.map { Date().timeIntervalSince($0) <= OR.Timing.rememberQuery } ?? true)
        if !remembered, draft?.isDirty != true, onboarding == nil {
            resetToHome()
        } else if !query.isEmpty {
            selectsQueryOnFocus = true
        }
        if section == .windows { refreshTargetWindow() }
    }

    func panelDidHide() {
        lastHiddenAt = .now
        showActions = false
        showShortcuts = false
        showsAttachmentPreview = false
        confirmation = nil
        // Showing again restarts them in resumeSearch().
        cancelProvidedLiveItems()
        // The editor stays open while hidden, so an emptied note is kept until it closes.
        if draft?.isNote == true { draft?.saveNote() }
    }

    private func resetToHome() {
        if editor != nil { editor = nil }
        destination = .search
        argumentLink = nil
        section = .home
        scopeReturnQuery = nil
        aiReturn = nil
        if !query.isEmpty { query = "" }
        feedback = nil
        selectedID = nil
        synchronizeSelection()
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

    /// Refreshes the real state either way, so the toggle never shows a change that didn't happen.
    func setLaunchAtLogin(_ enabled: Bool) {
        defer { refreshPermissions() }
        guard clipboard.usesGeneralPasteboard else {
            let message = "Open at login is off for the isolated verification instance."
            loginError = message
            feedback = .info(message)
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            let message = "Open at login couldn't be changed. \(error.localizedDescription)"
            loginError = message
            feedback = .error(message)
        }
    }

    func refreshTargetWindow() {
        targetWindowTitle = targetWindow?.title ?? windows.focusedWindowTitle(of: previousApplication)
    }

    /// Layouts apply to this window until the source app changes.
    func selectTargetWindow(_ window: WindowManager.TargetWindow) {
        // Set the app first: changing it clears any earlier choice.
        previousApplication = NSRunningApplication(processIdentifier: window.pid)
        targetWindow = window
        targetWindowTitle = window.title
    }

    // MARK: - Navigation

    func navigate(to section: LauncherSection) {
        if section != .home, self.section == .home, destination == .search, argumentLink == nil {
            scopeReturnQuery = query
        }
        if section == .home { scopeReturnQuery = nil }
        destination = .search
        argumentLink = nil
        self.section = section
        query = ""
        searchChanged()
        feedback = nil
        showActions = false
        confirmation = nil
        if section == .windows { refreshTargetWindow() }
        synchronizeSelection()
        focusRequest += 1
    }

    /// Leaves the current scope and restores the query from before it.
    func leaveScope() {
        let restored = scopeReturnQuery ?? ""
        scopeReturnQuery = nil
        destination = .search
        argumentLink = nil
        section = .home
        query = restored
        searchChanged()
        feedback = nil
        confirmation = nil
        synchronizeSelection()
        focusRequest += 1
    }

    /// Writing commands always run fresh on the current selection. A query or
    /// attachment starts a new chat, unless it is the question that started the
    /// chat on screen; opening AI with neither resumes the chat as it was.
    func openAI(
        _ action: AIAction = .chat, prompt: String? = nil, attachment: AIAttachment? = nil, command: AICommandRun? = nil
    ) {
        // Slice 7: agents, tools and saved chats connect on first use.
        _ = aiHub
        if let command {
            // An AI Command runs at once on the text it rendered (Slice 7).
            if destination == .search { aiReturn = (section, query) }
            destination = .ai
            argumentLink = nil
            files.stop()
            cancelProvidedLiveItems()
            showActions = false
            confirmation = nil
            feedback =
                ai.isGenerating ? .warning("Stop the current response or wait for it to finish before running another command.") : nil
            if !ai.isGenerating { ai.start(command) }
            focusRequest += 1
            return
        }
        let switchingWhileBusy = ai.isGenerating && (ai.action != action || ai.command != nil)
        if destination == .search { aiReturn = (section, query) }
        var sendPrompt = true
        // Reset before open(_:), so the engine is prepared for the new run.
        if !ai.isGenerating {
            if action != .chat, attachment == nil {
                ai.newConversation(action: action)
            } else if action == .chat, prompt?.isEmpty == false || attachment != nil {
                // Esc puts back the query that opened AI, which is the chat's first question.
                let firstQuestion =
                    ai.action == .chat ? ai.messages.first { $0.role == .user }.map { $0.displayText ?? $0.text } : nil
                if attachment == nil, firstQuestion == prompt, ai.messages.contains(where: { $0.role == .assistant }) {
                    // Esc then Tab on the same query returns to its chat, follow-ups included.
                    sendPrompt = false
                } else {
                    ai.newConversation(action: .chat)
                }
            }
        }
        ai.open(action)
        destination = .ai
        argumentLink = nil
        files.stop()
        cancelProvidedLiveItems()
        showActions = false
        confirmation = nil
        feedback =
            switchingWhileBusy
            ? .warning("Stop the current response or wait for it to finish before switching AI commands.") : nil
        guard !switchingWhileBusy else { return }
        if let attachment {
            ai.attach(attachment)
        } else if action != .chat, ai.attachments.isEmpty, ai.messages.isEmpty {
            attachSelectionFromPreviousApp()
        }
        if sendPrompt, let prompt, !prompt.isEmpty, action == .chat {
            // Without AI the question waits in the composer; it is never sent on its own later.
            ai.draft = prompt
            if ai.availability.isAvailable { ai.send() }
        }
        focusRequest += 1
    }

    /// Writing commands pick up the selected text from the app you came from.
    func attachSelectionFromPreviousApp(reportErrors: Bool = false) {
        guard clipboard.usesGeneralPasteboard || reportErrors || selectionReader != nil else { return }
        do {
            let text = try selectionReader?() ?? windows.selectedText(in: previousApplication)
            ai.attach(AIAttachment(source: .selection, text: text, appName: previousApplicationName))
        } catch {
            if reportErrors { feedback = .error(error.localizedDescription) }
        }
    }

    func attachClipboardToAI() {
        if let text = clipboard.readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ai.attach(AIAttachment(source: .clipboard, text: text))
        } else {
            feedback = .info("There's no text on the clipboard.")
        }
        focusRequest += 1
    }

    func leaveAI() {
        let destinationReturn = aiReturn
        aiReturn = nil
        showsAttachmentPreview = false
        destination = .search
        feedback = nil
        if let destinationReturn {
            section = destinationReturn.section
            query = destinationReturn.query
        } else {
            section = .home
            query = ""
        }
        searchChanged()
        synchronizeSelection()
        requestFocus()
    }

    /// Opens Settings at a pane, scrolled to a command's row when one is given.
    func openSettings(_ pane: SettingsPane? = nil, focusing commandID: String? = nil) {
        files.stop()
        showActions = false
        refreshPermissions()
        panel?.dismiss(restoreFocus: false)
        presentSettings?(pane, commandID)
    }

    func openHelp() {
        panel?.dismiss(restoreFocus: false)
        presentHelp?()
    }

    /// Esc closes exactly one layer: confirmation, overlays, actions, editor,
    /// AI, argument, scope, then the query. On an empty home it hides the panel.
    func goBack() {
        if confirmation != nil {
            confirmation = nil
        } else if showShortcuts {
            showShortcuts = false
        } else if showActions {
            showActions = false
        } else if showsAttachmentPreview {
            showsAttachmentPreview = false
        } else if editor != nil {
            closeEditor()
        } else if onboarding != nil {
            finishOnboarding()
        } else if destination == .ai {
            leaveAI()
        } else if argumentLink != nil {
            clearArgument(restoreKeyword: false)
        } else if section != .home {
            leaveScope()
        } else if !query.isEmpty {
            query = ""
        } else {
            panel?.dismiss()
        }
    }

    /// ⌫ on an empty field removes the token: first the argument, then the scope.
    func deleteBackwardOnEmptyField() -> Bool {
        if argumentLink != nil {
            clearArgument(restoreKeyword: true)
            return true
        }
        if destination == .ai, ai.draft.isEmpty {
            leaveAI()
            return true
        }
        if section != .home, destination == .search {
            leaveScope()
            return true
        }
        return false
    }

    /// Tab steps into a selected scope, starts a quicklink argument, or asks AI.
    /// A query asks AI from any scope, and Esc returns to that scope with it.
    func handleTab() {
        guard confirmation == nil, !showActions else { return }
        let item = selectedItem
        switch item?.action {
        case .section(let target)? where section == .home && !query.isEmpty:
            store.recordUse(of: item!.id)
            navigate(to: target)
        case .quicklink(let link, let argument)? where link.needsQuery && argument.isEmpty && argumentLink == nil:
            beginArgument(link)
        case .clipboard(let entry)?:
            if let text = entry.plainText {
                openAI(.chat, attachment: AIAttachment(source: .clipboard, text: text, appName: entry.sourceName))
            }
        default:
            guard argumentLink == nil else { return }
            let prompt = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if section == .home || !prompt.isEmpty { openAI(.chat, prompt: prompt) }
        }
    }

    func beginArgument(_ link: Quicklink) {
        if section == .home, destination == .search { scopeReturnQuery = nil }
        argumentLink = link
        query = ""
        selectedID = "argument.\(link.id)"
        focusRequest += 1
    }

    func clearArgument(restoreKeyword: Bool) {
        guard let link = argumentLink else { return }
        argumentLink = nil
        query = restoreKeyword ? link.keyword : ""
        searchChanged()
        synchronizeSelection()
        focusRequest += 1
    }

    // MARK: - Onboarding

    func beginOnboardingIfNeeded() {
        // A read-only library holds placeholder defaults, not a new user's.
        guard store.database.preferences.needsFirstRun, !store.isReadOnly, onboarding == nil else { return }
        let inMemory = store.fileURL == nil
        guard !inMemory || ProcessInfo.processInfo.arguments.contains("--first-run") else { return }
        onboarding = .shortcut
        onboardingHotKeyPressed = false
    }

    func advanceOnboarding() {
        guard let step = onboarding else { return }
        launcherHotKeyRefusal = nil
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            onboarding = next
        } else {
            finishOnboarding()
        }
    }

    func onboardingBack() {
        guard let step = onboarding, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        onboarding = previous
    }

    func finishOnboarding() {
        onboarding = nil
        launcherHotKeyRefusal = nil
        store.update { $0.preferences.firstRunCompleted = true }
        resetToHome()
        focusRequest += 1
    }

    // MARK: - Selection

    func resumeSearch() {
        if destination == .search, argumentLink == nil, section == .home || section == .files {
            files.search(query, showRecent: section == .files, scope: section == .files ? fileScope : .home)
        }
        refreshProvidedLiveItems()
    }

    func synchronizeSelection() {
        let items = orderedResults
        // A words-only answer chosen while search was pending stays chosen once it settles.
        if selectedID == CalculatorProvider.pendingWordAnswerID,
            items.contains(where: { $0.id == CalculatorProvider.wordAnswerID })
        {
            selectedID = CalculatorProvider.wordAnswerID
        }
        let preferred = ProvisionalSelection.defaultID(in: items)
        if !items.contains(where: { $0.id == selectedID }) {
            selectedID = preferred
        } else if !selectionMovedByHand, selectedID != preferred,
            ProvisionalSelection.followsDefault(selectedID: selectedID, items: items)
        {
            // See ProvisionalSelection: an untouched selection follows the default around a
            // words-only answer or Translate's language rows, so ↩ never lands on them by accident.
            selectedID = preferred
        }
    }

    /// Vertical movement. Grids move by row; lists move by one and wrap.
    func moveSelection(_ offset: Int) {
        guard !showActions else { return }
        let groups = groups
        let items = groups.flatMap(\.items)
        guard !items.isEmpty else { return }
        selectionWillChange()
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        defer {
            if selectedID != items[index].id { announceSelection(items.first { $0.id == selectedID }) }
        }
        var start = 0
        for group in groups {
            let range = start..<(start + group.items.count)
            start += group.items.count
            guard range.contains(index), let columns = Self.columns(for: group) else { continue }
            let target = index + offset * columns
            if range.contains(target) {
                selectedID = items[target].id
            } else if offset > 0, (index - range.lowerBound) / columns < (range.count - 1) / columns {
                // ↓ above a partial last row lands on its last tile rather than skipping it.
                selectedID = items[range.upperBound - 1].id
            } else {
                // Leaving a grid lands on the nearest row outside it.
                let outside = offset > 0 ? range.upperBound : range.lowerBound - 1
                selectedID = items[(outside + items.count) % items.count].id
            }
            return
        }
        selectedID = items[(index + offset + items.count) % items.count].id
    }

    /// Horizontal movement inside grids. Returns false when the selection is in a list.
    @discardableResult
    func moveSelectionHorizontally(_ offset: Int) -> Bool {
        guard !showActions else { return false }
        let groups = groups
        let items = groups.flatMap(\.items)
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        var start = 0
        for group in groups {
            let range = start..<(start + group.items.count)
            start += group.items.count
            guard range.contains(index), Self.columns(for: group) != nil else { continue }
            let target = index + offset
            if range.contains(target), target != index {
                selectionWillChange()
                selectedID = items[target].id
                announceSelection(items[target])
            }
            return true
        }
        return false
    }

    /// Moving the selection by hand drops a pending confirmation and a stale error.
    /// Programmatic selection (search, delete, ⌘-numbers) keeps its feedback.
    private func selectionWillChange() {
        selectionMovedByHand = true
        confirmation = nil
        if feedback?.style == .error || feedback?.style == .warning { feedback = nil }
    }

    /// Speaks the row the arrow keys moved to. Query changes reset the selection
    /// on every keystroke, so they deliberately don't announce.
    private func announceSelection(_ item: LauncherItem?) {
        guard let item, NSWorkspace.shared.isVoiceOverEnabled else { return }
        announceForVoiceOver(
            [item.accessibilityDescription, item.subtitle, primaryTitle(for: item)].filter { !$0.isEmpty }
                .joined(separator: ". "))
    }

    /// Posts a VoiceOver announcement without moving focus. Medium priority
    /// keeps toasts, which are announced at high priority, in front.
    func announceForVoiceOver(_ text: String) {
        // Never speaks from the test host or verification mode.
        guard !SideEffectGuard.isInert, NSWorkspace.shared.isVoiceOverEnabled, !text.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Whether ← and → should move the selection rather than the caret.
    var arrowsMoveSelection: Bool {
        guard destination == .search, argumentLink == nil, !showActions else { return false }
        if section == .windows || section.providedScope?.style == .grid { return true }
        return section == .home && isQueryBlank
    }

    /// A group's grid width, shared by drawing and keyboard movement. Nil for lists.
    static func columns(for group: LauncherResultGroup) -> Int? {
        guard let columns = columns(for: group.style) else { return nil }
        return max(1, group.columns ?? columns)
    }

    nonisolated static func columns(for style: LauncherResultGroup.Style) -> Int? {
        switch style {
        case .favorites: 8
        case .grid: 4
        default: nil
        }
    }

    // MARK: - Query

    private func searchChanged() {
        selectedID = nil
        selectionMovedByHand = false
        searchGeneration += 1
        if feedback?.style != .working { feedback = nil }
        confirmation = nil
        guard query.count <= 512 else {
            files.stop()
            cancelProvidedLiveItems()
            feedback = .warning("Keep searches under 512 characters. For a longer passage, press Tab to ask AI.")
            return
        }
        // Typing a quicklink keyword and a space turns it into an argument token.
        if section == .home, destination == .search, argumentLink == nil,
            let (link, argument) = quicklinkArgument(in: query)
        {
            argumentLink = link
            query = argument
            return
        }
        if argumentLink == nil, section == .home || section == .files {
            files.search(query, showRecent: section == .files, scope: section == .files ? fileScope : .home)
        } else {
            files.stop()
        }
        refreshProvidedLiveItems()
    }

    /// Live provider rows, in registration order, for `results`.
    private var providedLiveItemsInOrder: [LauncherItem] {
        guard !providedLiveItems.isEmpty else { return [] }
        return registry.providers.flatMap { providedLiveItems[$0.id] ?? [] }
    }

    /// Starts the providers' live searches for the current query, replacing any still running.
    /// Root search asks every provider with one once there's a query; a provided scope asks its
    /// owner. Each provider runs on its own task, so a slow one never holds up the others, and
    /// an answer that arrives after the query changed is dropped.
    func refreshProvidedLiveItems() {
        cancelProvidedLiveItems()
        let scope = section.providedScope
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard destination == .search, argumentLink == nil, query.count <= 512,
            scope != nil || (section == .home && !term.isEmpty)
        else { return }
        let generation = liveGeneration
        for providerID in registry.liveProviders(for: scope).map(\.id) {
            pendingLiveProviderIDs.insert(providerID)
            providedLiveTasks.append(
                Task { [weak self] in
                    guard let provider = self?.registry.provider(id: providerID), let model = self else { return }
                    let rows = await provider.liveItems(for: term, scope: scope, in: model)
                    guard let self, !Task.isCancelled, self.liveGeneration == generation else { return }
                    // Root-search rows never become the Top Hit; see searchGroups.
                    self.providedLiveItems[providerID] = rows.map { row in
                        var row = row
                        row.isLiveResult = scope == nil
                        return row
                    }
                    self.pendingLiveProviderIDs.remove(providerID)
                })
        }
    }

    /// Stops every live search and forgets its rows: on a new query, on hide, and on leaving search.
    func cancelProvidedLiveItems() {
        liveGeneration += 1
        for task in providedLiveTasks { task.cancel() }
        providedLiveTasks = []
        if !pendingLiveProviderIDs.isEmpty { pendingLiveProviderIDs = [] }
        if !providedLiveItems.isEmpty { providedLiveItems = [:] }
    }

    /// What an empty provided scope says: the provider's words, or a generic searching, empty
    /// or no-matches message.
    func providedEmptyState(for scope: ProvidedScope) -> ProvidedEmptyState {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let state = registry.emptyState(for: scope, query: term, isLoading: isLoadingProvidedItems, in: self) {
            return state
        }
        if isLoadingProvidedItems {
            return ProvidedEmptyState(title: "Searching \(scope.title)…", detail: "Results appear as they arrive.")
        }
        if term.isEmpty {
            return ProvidedEmptyState(
                title: "No \(scope.itemNoun)s yet", detail: "There's nothing in \(scope.title) right now.")
        }
        return ProvidedEmptyState(
            title: "No matches for “\(term.truncatedForFeedback)”",
            detail: "Try a different name or keyword, or clear the search to see everything in \(scope.title).",
            symbol: "magnifyingglass")
    }

    private func quicklinkArgument(in input: String) -> (Quicklink, String)? {
        for link in store.database.quicklinks where link.needsQuery && !link.keyword.isEmpty {
            let prefix = link.keyword + " "
            guard input.count > prefix.count - 1, input.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            let argument = String(input.dropFirst(prefix.count)).replacingOccurrences(
                of: "^\\s+", with: "", options: .regularExpression)
            return (link, argument)
        }
        return nil
    }

    // MARK: - Feedback

    private func scheduleFeedbackExpiry() {
        feedbackTask?.cancel()
        guard let feedback, feedback.expires else { return }
        let id = feedback.id
        feedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: OR.Timing.toast) } catch { return }
            guard let self, self.feedback?.id == id else { return }
            self.feedback = nil
        }
    }

    func toast(_ text: String) { feedback = .success(text) }

    /// Returns the keyboard to the field. Requested again on the next run loop,
    /// because a closing layer can take the shared field editor with it.
    func requestFocus() {
        focusRequest += 1
        DispatchQueue.main.async { [weak self] in self?.focusRequest += 1 }
    }

    // MARK: - Editors

    private func editorDidChange(from old: LibraryEditor?) {
        guard editor?.id != old?.id || (editor == nil) != (old == nil) else { return }
        if old != nil, draft?.isNote == true { draft?.finishNote() }
        draft = editor.map { EditorDraft(editor: $0, store: store) }
        // Editing again withdraws “Discard changes?”, so a later ↩ can't discard the new edits.
        draft?.onEdit = { [weak self] in
            if case .discardChanges? = self?.confirmation { self?.confirmation = nil }
        }
        confirmation = nil
        showActions = false
        if editor == nil { requestFocus() }
    }

    /// Esc on an editor: notes save as they close; others ask before discarding.
    /// A note that couldn't be saved asks too, rather than losing the text.
    func closeEditor(force: Bool = false) {
        guard let draft else {
            editor = nil
            return
        }
        if draft.isNote {
            guard draft.finishNote() || force else {
                confirmation = .discardChanges
                return
            }
            let noteID = editor?.id
            editor = nil
            // An emptied note was removed, so there's nothing to select.
            if section == .notes, let noteID, store.database.notes.contains(where: { "note.\($0.id)" == noteID }) {
                selectedID = noteID
            }
            return
        }
        if draft.isDirty && !force {
            confirmation = .discardChanges
            return
        }
        editor = nil
    }

    func saveEditor() {
        guard let draft else { return }
        if draft.isNote {
            if draft.saveNote() { toast("Saved") }
            return
        }
        guard draft.save() else {
            // The editor moves focus to the field; VoiceOver hears why. Posted directly,
            // not as feedback, so pressing ⌘S again repeats the same message.
            if draft.saveError == nil,
                let message = draft.nameError ?? (draft.isQuicklink ? draft.contentError : nil) ?? draft.keywordError
                    ?? draft.contentError
            {
                announceForVoiceOver(message)
            }
            return
        }
        let id = editor?.id
        let noun = draft.isSnippet ? "snippet" : "quicklink"
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        editor = nil
        if let id {
            selectedID = id
        }
        toast("Saved \(noun) “\(name.truncatedForFeedback)”")
    }

    func createItem() {
        // Never replace unsaved edits silently. Notes save as they close.
        if let draft, !draft.isNote, draft.isDirty {
            confirmation = .discardChanges
            return
        }
        switch section {
        case .snippets: editor = .snippet(Snippet(name: "", keyword: "", content: ""))
        case .quicklinks: editor = .quicklink(Quicklink(name: "", template: "https://", keyword: ""))
        case .notes: editor = .note(QuickNote(title: "", content: ""))
        default: break
        }
    }

    // MARK: - Helpers

    var defaultBrowserName: String {
        if let browserName { return browserName }
        let name =
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? "Browser"
        browserName = name
        return name
    }

    nonisolated static func siteName(for link: Quicklink) -> String {
        let template = link.template.replacingOccurrences(of: "{query}", with: "")
        guard let host = URL(string: template)?.host?.lowercased() else { return link.name }
        let known: [String: String] = [
            "duckduckgo.com": "DuckDuckGo", "github.com": "GitHub", "www.google.com": "Google", "google.com": "Google",
            "developer.apple.com": "Apple Developer", "www.bing.com": "Bing", "kagi.com": "Kagi",
            "en.wikipedia.org": "Wikipedia", "www.youtube.com": "YouTube", "stackoverflow.com": "Stack Overflow",
            "maps.apple.com": "Apple Maps", "www.amazon.com": "Amazon", "news.ycombinator.com": "Hacker News",
        ]
        if let name = known[host] { return name }
        let parts = host.replacingOccurrences(of: "www.", with: "").split(separator: ".")
        return parts.count >= 2 ? parts[parts.count - 2].capitalized : host
    }

    nonisolated static func displayURL(_ string: String, decoding: Bool = true) -> String {
        var display = string
        for prefix in ["https://", "http://"] where display.hasPrefix(prefix) { display.removeFirst(prefix.count) }
        if display.hasPrefix("www.") { display.removeFirst(4) }
        return decoding ? (display.removingPercentEncoding ?? display) : display
    }

    nonisolated static func shortenedPath(_ url: URL) -> String {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
