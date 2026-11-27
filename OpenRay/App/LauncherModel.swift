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
    /// Every assignment is a new prompt instance, even when it asks the same question again, so
    /// nothing armed for an earlier one carries over.
    var confirmation: ActionConfirmation? {
        didSet {
            confirmationToken = UUID()
            confirmationShown = nil
        }
    }
    /// Identifies the current prompt instance; see `confirmationInstanceID`.
    private(set) var confirmationToken = UUID()
    /// The prompt instance a visible action bar last reported showing, and when. Only it can be
    /// approved, and only once it has been on screen for `minimumPromptExposure`.
    @ObservationIgnored var confirmationShown: (instance: String, at: Date)?
    /// Since when the surface showing prompts has been on screen, opaque and key; nil while it
    /// isn't. Nil asks the panel; tests set it.
    @ObservationIgnored var confirmationSurfaceVisibleSince: (() -> Date?)?
    /// Whether a field's submit stands for a fresh Return. Always false in the app: only the
    /// panel's own Return, judged from its key event, answers a prompt, and a submit is no
    /// evidence of a key press. Tests set it to stand in for that Return.
    @ObservationIgnored var currentKeyPressIsFresh: () -> Bool = { false }
    /// The clock prompt exposure is measured with. Tests set it.
    @ObservationIgnored var promptClock: () -> Date = Date.init
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
    /// The launcher shortcut registered right now, which can differ from the saved one when
    /// registration fell back. Nil until registration runs, or while nothing is registered.
    var activeLauncherShortcut: CommandShortcut?
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
    /// Query picks and search history; see LauncherModel+Launcher.
    let memory: LauncherMemoryStore
    /// Open argument fields. Set through `beginArguments(…)`, cleared by run or cancel.
    var argumentSession: ArgumentSession?
    /// Open action-panel submenus, outermost first.
    var actionPath: [ActionEntry] = []
    /// The search history entry ↑ last recalled.
    @ObservationIgnored var historyCursor: Int?
    /// Bumped whenever live searches restart or stop, so a late answer for an earlier query is dropped.
    @ObservationIgnored private var liveGeneration = 0
    let applications = ApplicationCatalog()
    let files = FileSearchService()
    let ai: AIChatModel
    let windows = WindowManager()
    // main: pomodoro, caffeinate
    /// The Pomodoro timer. Its state lives in the library, so it keeps running while the panel is hidden.
    let pomodoro: PomodoroService
    /// Keeps the Mac awake. Owned for the whole launch; quitting releases it.
    let caffeinate: CaffeinateService
    /// Caffeinate's pending duration controls, kept across navigation and hiding until submitted.
    let caffeinateDraft = CaffeinateDraft()
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
    /// The Hyper key, when turned on. Applied only in a normal launch, never in tests.
    @ObservationIgnored let hyperKey: HyperKey
    /// This launch's rule for side effects on the Mac. Executors the model runs check it first.
    @ObservationIgnored let sideEffects: SideEffectGuard
    @ObservationIgnored weak var panel: LauncherPanelController?
    @ObservationIgnored var previousApplication: NSRunningApplication? {
        didSet {
            // A new source app means a new context; a chosen window doesn't carry over.
            targetWindow = nil
            if !isRetargetingWindow { foregroundApplication = previousApplication }
            if previousApplication != oldValue { previousApplicationName = previousApplication?.localizedName }
        }
    }
    private(set) var previousApplicationName: String?
    /// The app that was frontmost when the launcher opened or a hotkey ran. Choosing a window
    /// with the target chip changes `previousApplication`, never this.
    @ObservationIgnored private(set) var foregroundApplication: NSRunningApplication?
    @ObservationIgnored private var isRetargetingWindow = false
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
    /// Stands in for the whole selection capture, target included. Tests set it with
    /// `setCapturedSelection(_:)`.
    @ObservationIgnored var selectionContextReader: (() throws -> SelectedTextContext)?
    /// Stands in for the ⌘C fallback when Accessibility saw no selection. Tests set it.
    @ObservationIgnored var selectionCopyReader: ((NSRunningApplication?) async throws -> SelectedTextContext)?
    /// How the live ⌘C fallback reaches the source app; see `SelectionCopy`.
    @ObservationIgnored var selectionCopyEnvironment = SelectionCopy.Environment.live
    /// Stands in for Quick Fix's read of the whole focused field. Tests set it.
    @ObservationIgnored var focusedFieldReader: (() throws -> FocusedFieldContext)?
    /// The selection `{selection}` last read, so an AI Command that replaces it can pin it.
    @ObservationIgnored var lastCapturedSelection: SelectedTextContext?
    /// The selection a writing result goes back over (main #13): pinned to its conversation and
    /// its passage, never to whichever app happens to be in front later.
    var aiSelectionTarget: PinnedSelection?
    /// The app the run on screen pastes into, bound when the run started.
    var aiDestination: RunDestination?
    /// The ⌘C fallback under way, so dismissal and the person's input can stop it.
    @ObservationIgnored var selectionCaptureSession: SelectionCaptureSession?
    /// Watches the person's keys and clicks in OpenRay while a selection is copied. Inert launches
    /// install nothing; tests pass a fake.
    @ObservationIgnored var inputMonitoring: any LocalEventMonitoring = AppKitLocalEventMonitoring()
    /// Whether an app's focused element is a password field, read right before a paste. Tests set it.
    @ObservationIgnored var focusedFieldIsSecure: @MainActor (NSRunningApplication) -> Bool = {
        SelectedTextContext.focusedFieldIsSecure(in: $0)
    }
    /// The app in front now, read before a windowless run brings the panel up. Tests set it.
    @ObservationIgnored var frontmostProcess: @MainActor () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    /// Stands in for the panel's visibility; tests have no panel.
    @ObservationIgnored var panelVisibility: (@MainActor () -> Bool)?
    /// True while a result is being pasted into its app.
    var isPastingAIResponse = false
    /// The app the ⌘C fallback is reading the selection from, while it does.
    var readingSelectionFrom: String?
    /// Why a writing command opened without a selection, such as “Nothing selected in Notes.”
    var selectionNotice: String?
    @ObservationIgnored var selectionCaptureTask: Task<Void, Never>?
    /// The last paste back or in-place run, while it runs. Tests await them.
    @ObservationIgnored var pasteBackTask: Task<Void, Never>?
    @ObservationIgnored var inPlaceTask: Task<Void, Never>?
    /// How a paste back reaches the app. Nil uses the live one in a normal launch; an inert launch
    /// only copies. Tests pass fakes.
    @ObservationIgnored var pasteBackEnvironment: PasteBack.Environment?
    /// The HUD a paste back or in-place run confirms with. Tests pass one with a fake presenter.
    @ObservationIgnored var hud: HUDController = .shared
    /// Builds the conversation an in-place run uses, apart from the panel's. Tests set it.
    @ObservationIgnored var unattendedChatFactory: (() -> AIChatModel)?

    /// Writing runs, oldest first: every run with work, kept when a new selection starts another,
    /// so ⌘[ and ⌘] can bring it back. The run on screen is in it once it's put away.
    var writingRuns: [StashedWriting] = []
    /// How many writing runs the history keeps.
    nonisolated static let writingHistoryLimit = 20
    /// Set when a timer scope was opened from AI, so Back returns to the AI work it left.
    @ObservationIgnored var scopeReturnsToAI = false
    /// Scopes that are detours from AI: Back from them returns to AI (main #10/#11).
    nonisolated static let aiDetourProviders: Set<String> = ["pomodoro", "caffeinate"]

    struct StashedWriting {
        var snapshot: AIChatModel.WritingSnapshot
        var pin: PinnedSelection?
        var destination: RunDestination?
    }

    /// The app a run's result is pasted into: bound when the run starts, kept with it in history,
    /// and never swapped for whichever app is in front later (review blocker 6).
    struct RunDestination {
        var conversation: UUID
        var application: NSRunningApplication
        var processIdentifier: pid_t
        var bundleIdentifier: String?
        var name: String
        /// Whether the field focused at capture still is; nil when there was none to check.
        var focusIsOriginal: (@MainActor () -> Bool?)?

        init(conversation: UUID, application: NSRunningApplication, name: String, focusIsOriginal: (@MainActor () -> Bool?)?) {
            self.conversation = conversation
            self.application = application
            processIdentifier = application.processIdentifier
            bundleIdentifier = application.bundleIdentifier
            self.name = name
            self.focusIsOriginal = focusIsOriginal
        }

        /// The bound app while it's still the same running app; nil once it quit.
        var liveApplication: NSRunningApplication? {
            guard !application.isTerminated, application.processIdentifier == processIdentifier,
                application.bundleIdentifier == bundleIdentifier
            else { return nil }
            return application
        }
    }

    /// A selection a result goes back over, bound to the passage the person chose: the attachment
    /// that carried it, in this conversation. Another source with the same text never matches.
    /// An AI Command's run has no attachment; its conversation is enough.
    struct PinnedSelection {
        var context: SelectedTextContext
        var conversation: UUID
        var attachmentID: AIAttachment.ID?
    }

    /// Defaults follow `SideEffectGuard`: a normal launch uses the library on disk and the system
    /// clipboard; the test host and verification mode get an in-memory library and a private,
    /// uniquely named pasteboard, so a default-built model can't touch the person's data.
    init(
        store: LibraryStore? = nil, ai: AIChatModel = AIChatModel(), pasteboard: NSPasteboard? = nil,
        registry: CommandRegistry = CommandRegistry(), hotKey: GlobalHotKey? = nil, hyperKey: HyperKey? = nil,
        sideEffects: SideEffectGuard = .current, caffeinate: CaffeinateService? = nil,
        pomodoroSound: (() -> Void)? = nil
    ) {
        // An injected live guard never makes an inert process (tests, verification) act for real.
        let sideEffects = sideEffects.effective
        self.sideEffects = sideEffects
        let store = store ?? LibraryStore(fileURL: sideEffects.isInert ? nil : LibraryStore.defaultURL)
        let pasteboard = pasteboard ?? (sideEffects.isInert ? NSPasteboard.withUniqueName() : .general)
        self.hyperKey = hyperKey ?? HyperKey()
        self.store = store
        self.registry = registry
        memory = LauncherMemoryStore(fileURL: LauncherMemoryStore.fileURL(besideLibrary: store.fileURL))
        self.hotKey = hotKey ?? GlobalHotKey()
        usesInjectedHotKey = hotKey != nil
        self.ai = ai
        // The real assertion and chime check the side-effect guard themselves; tests pass fakes.
        self.caffeinate = caffeinate ?? CaffeinateService()
        pomodoro = PomodoroService(store: store, playCompletionSound: pomodoroSound ?? PomodoroService.playSystemSound)
        clipboard = ClipboardService(store: store, pasteboard: pasteboard)
        snippets = SnippetExpander(store: store)
        // {clipboard} in expanded snippets reads through the service, which skips excluded copies.
        snippets.clipboardReader = { [clipboard] in clipboard.placeholderText() }
        fileScope = store.database.preferences.fileSearchScope ?? .home
        connectFilesAndApplications()
        store.commandBindingsDidChange = { [weak self] in self?.synchronizeCommandHotKeys() }
        reconcileJournaledCleanup()
    }

    /// Deletions an earlier session recorded but couldn't finish: cleans up after rows their
    /// provider says are gone, drops the records of rows that still exist, and keeps the rest for
    /// the next launch or catalog change.
    func reconcileJournaledCleanup() {
        guard !store.journaledCleanup.isEmpty else { return }
        store.reconcileJournaledCleanup { [registry] id, provider in
            switch registry.presence(ofItemWithID: id, provider: provider, in: self) {
            case .gone: true
            case .present: false
            case .unknown: nil
            }
        }
    }

    /// Compatibility shim: the last error or notice, as text.
    var message: String? {
        get { feedback?.text }
        set { feedback = newValue.map { .error($0) } }
    }

    // MARK: - Results

    var results: [LauncherItem] {
        guard query.count <= 512 else { return [] }
        if let session = argumentSession { return [session.item] }
        if let link = argumentLink { return argumentItems(for: link) }
        // Aliases are a single global namespace, independent of section, usage,
        // favorites, quicklink arguments and calculator interpretation.
        if let targetID = store.database.aliasTarget(for: query),
            let command = bindableCommands.first(where: { $0.id == targetID })
        {
            return [command]
        }
        // A typed path, a content search and the Files scope rank their own rows.
        if let rows = fileSearchRows { return rows }
        var items: [LauncherItem] = []
        switch section {
        case .home:
            items = withoutDisabledCommands(commandItems) + applicationItems + quicklinkItems + snippetItems + noteItems + savedFileItems
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
            let learned = memory.memory.picks[LauncherMemory.normalize(trimmed)] ?? [:]
            let hasAliases = section == .home && store.database.commandBindings.contains { $0.alias != nil }
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
                // An alias the query starts ranks just below an exact title.
                let aliasScore = hasAliases ? aliasPrefixScore(for: item, query: trimmed) : nil
                guard let score = [titleScore, keywordScore, aliasScore].compactMap({ $0 }).max() else { return nil }
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
                // What you picked for this query before comes first among similar matches.
                let learnedBoost = Self.learnedBoost(learned[item.id] ?? 0)
                return (item, score + appBoost + commandBoost + favoriteBoost + usageBoost + learnedBoost)
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
        // On blank Home, favorites and pinned clipboard entries are what you put there: however
        // many commands the slices add ahead of them, the cap never pushes them out.
        let kept: Set<String> =
            section == .home && trimmed.isEmpty
            ? store.database.favoriteIDs.union(store.database.clipboard.lazy.filter(\.isPinned).map { "clipboard.\($0.id)" })
            : []
        let shown = Self.capped(items, in: section, keeping: kept)
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
    /// so a flood of late files can never push out the Top Hit. Scopes show 100. Rows in `kept`
    /// stay wherever they are and don't count toward Home's 45.
    nonisolated static func capped(
        _ items: [LauncherItem], in section: LauncherSection, keeping kept: Set<String> = []
    ) -> [LauncherItem] {
        guard section == .home else { return Array(items.prefix(100)) }
        var budget = 45
        let instant = items.filter { item in
            guard !item.isLiveResult else { return false }
            if kept.contains(item.id) { return true }
            guard budget > 0 else { return false }
            budget -= 1
            return true
        }
        let live = items.filter(\.isLiveResult).prefix(20)
        return instant + Array(live)
    }

    /// True when the query is empty or only whitespace.
    var isQueryBlank: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Bar mode shows only the field while Home is idle. Anything that needs to
    /// be seen, such as a toast, an error or a delete prompt, expands it.
    var isCollapsedToBar: Bool {
        store.database.preferences.usesBarMode && destination == .search && editor == nil && onboarding == nil
            && section == .home && isQueryBlank && argumentLink == nil && argumentSession == nil && !showActions
            && feedback == nil
            && confirmation == nil && store.errorMessage == nil && shortcutError == nil
    }

    var groups: [LauncherResultGroup] {
        // Open argument fields own the list: their command, whatever the query or scope.
        if let session = argumentSession {
            return [LauncherResultGroup(id: "argument.session", title: nil, items: [session.item])]
        }
        if let link = argumentLink {
            let items = argumentItems(for: link)
            return [
                LauncherResultGroup(id: "argument", title: nil, items: Array(items.prefix(1))),
                LauncherResultGroup(id: "elsewhere", title: "Same search elsewhere", items: Array(items.dropFirst())),
            ].filter { !$0.items.isEmpty }
        }
        if let fileGroups = fileSearchGroups { return fileGroups }
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
            (withoutDisabledCommands(commandItems) + applicationItems + quicklinkItems + snippetItems + noteItems
                + savedFileItems + clipboardItems).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let disabled = store.database.disabledCommandIDs
        return store.database.orderedFavoriteIDs.compactMap {
            index[$0] ?? (disabled.contains($0) ? nil : registry.item(withID: $0, in: self))
        }
        .prefix(16).map { $0 }
    }

    private var homeGroups: [LauncherResultGroup] {
        let favorites = favoriteItems
        let favoriteIDs = Set(favorites.map(\.id))
        let index = Dictionary(
            (withoutDisabledCommands(commandItems) + applicationItems + quicklinkItems + snippetItems + noteItems
                + savedFileItems).map {
                ($0.id, $0)
            }, uniquingKeysWith: { first, _ in first })
        let disabled = store.database.disabledCommandIDs
        // Clipboard entries stay out of Everything unless they are favorites.
        let recent = store.database.usage.sorted { $0.lastUsed > $1.lastUsed }
            .filter { !favoriteIDs.contains($0.id) && !$0.id.hasPrefix("clipboard.") }
            .compactMap { index[$0.id] ?? (disabled.contains($0.id) ? nil : registry.item(withID: $0.id, in: self)) }
            .prefix(4)
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

    /// Ask AI and the web search unless the person chose others; see LauncherModel+Launcher.
    private var fallbackItems: [LauncherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return orderedFallbackItems(for: trimmed)
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
        pomodoro.startMonitoring()
        await applications.refresh()
        // Apps can hold hotkeys, so register them once the catalog is known.
        commandCatalogDidChange()
    }

    /// Rescans the app folders, then re-registers app hotkeys.
    func refreshApplications() async {
        await applications.refresh()
        commandCatalogDidChange()
    }

    func stop() {
        isStarted = false
        isRecordingShortcut = false
        hotKey.unregister()
        clipboard.stop()
        snippets.stop()
        files.stop()
        cancelProvidedLiveItems()
        hyperKey.stop()
        ai.cancel()
        pomodoro.stopMonitoring()
        // Keeping the Mac awake ends with the launcher, as it does when OpenRay quits.
        caffeinate.shutdown()
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
        let delay = store.database.preferences.popToRootDelay.interval
        let remembered =
            delay != 0 && (lastHiddenAt.map { hidden in delay.map { Date().timeIntervalSince(hidden) <= $0 } ?? true } ?? true)
        // A reply still being written is never hidden behind Home (main #12): you come back to it.
        let writing = destination == .ai && ai.isGenerating
        if !remembered, draft?.isDirty != true, onboarding == nil, !writing {
            resetToHome()
        } else if !query.isEmpty {
            selectsQueryOnFocus = true
        }
        if section == .windows { refreshTargetWindow() }
        // A phase or a timed session may have ended while the panel was hidden.
        pomodoro.refresh()
        caffeinate.refresh()
    }

    func panelDidHide() {
        lastHiddenAt = .now
        // A selection still being copied stops: from now on a clipboard change is the person's.
        cancelSelectionCapture()
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
        argumentSession = nil
        destination = .search
        argumentLink = nil
        section = .home
        scopeReturnQuery = nil
        aiReturn = nil
        scopeReturnsToAI = false
        if !query.isEmpty { query = "" }
        feedback = nil
        selectedID = nil
        synchronizeSelection()
    }

    func refreshPermissions() {
        accessibilityAllowed = windows.hasPermission
        // The Hyper key follows its setting and Accessibility; inert launches never change keys.
        if isStarted, !sideEffects.isInert {
            hyperKey.apply(store.database.preferences.hyper, accessibilityAllowed: accessibilityAllowed)
        }
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
        // Set the app first: changing it clears any earlier choice. The foreground app stays.
        isRetargetingWindow = true
        defer { isRetargetingWindow = false }
        previousApplication = NSRunningApplication(processIdentifier: window.pid)
        targetWindow = window
        targetWindowTitle = window.title
    }

    // MARK: - Navigation

    func navigate(to section: LauncherSection) {
        scopeReturnsToAI =
            destination == .ai && section.providedScope.map { Self.aiDetourProviders.contains($0.provider) } == true
        if section != .home, self.section == .home, destination == .search, argumentLink == nil {
            scopeReturnQuery = query
        }
        if section == .home { scopeReturnQuery = nil }
        destination = .search
        argumentLink = nil
        argumentSession = nil
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

    /// Leaves the current scope and restores the query from before it, or the AI work a timer
    /// was opened from.
    func leaveScope() {
        if scopeReturnsToAI {
            scopeReturnsToAI = false
            argumentLink = nil
            argumentSession = nil
            section = .home
            if !query.isEmpty { query = "" }
            destination = .ai
            feedback = nil
            confirmation = nil
            focusRequest += 1
            return
        }
        let restored = scopeReturnQuery ?? ""
        scopeReturnQuery = nil
        destination = .search
        argumentLink = nil
        argumentSession = nil
        section = .home
        query = restored
        searchChanged()
        feedback = nil
        confirmation = nil
        synchronizeSelection()
        focusRequest += 1
    }

    /// Writing commands start a new run on the selection in the app you came from, at once
    /// (work items 1 and 3); without one, the passage editor says why. A query or attachment
    /// starts a new chat, unless it is the question that started the chat on screen; opening AI
    /// with neither resumes the chat as it was.
    func openAI(
        _ action: AIAction = .chat, prompt: String? = nil, attachment: AIAttachment? = nil, command: AICommandRun? = nil
    ) {
        // Slice 7: agents, tools and saved chats connect on first use.
        _ = aiHub
        if let command {
            // An AI Command runs at once on the text it rendered (Slice 7).
            if destination == .search { aiReturn = (section, query) }
            enterAIView()
            feedback =
                ai.isGenerating ? .warning("Stop the current response or wait for it to finish before running another command.") : nil
            if !ai.isGenerating {
                cancelSelectionCapture()
                commitWritingRun()
                selectionNotice = nil
                ai.start(command)
                // The selection the command read is where its result goes back.
                if let selection = lastCapturedSelection {
                    aiSelectionTarget = PinnedSelection(
                        context: selection, conversation: ai.conversationToken, attachmentID: nil)
                }
                bindDestination(to: lastCapturedSelection)
            }
            focusRequest += 1
            return
        }
        if action != .chat {
            openWriting(action, attachment: attachment)
            return
        }
        let switchingWhileBusy = ai.isGenerating && (ai.action != action || ai.command != nil)
        if destination == .search { aiReturn = (section, query) }
        var sendPrompt = true
        // Writing work goes into the history first, never dropped (main #12/#13).
        if !ai.isGenerating {
            if ai.action != .chat || ai.command != nil { commitWritingRun() }
            if prompt?.isEmpty == false || attachment != nil {
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
        enterAIView()
        feedback =
            switchingWhileBusy
            ? .warning("Stop the current response or wait for it to finish before switching AI commands.") : nil
        guard !switchingWhileBusy else { return }
        if let attachment { ai.attach(attachment) }
        if sendPrompt, let prompt, !prompt.isEmpty {
            // Without AI the question waits in the composer; it is never sent on its own later.
            ai.draft = prompt
            if ai.availability.isAvailable { ai.send() }
        }
        focusRequest += 1
    }

    /// Shows the AI view in place of search.
    private func enterAIView() {
        destination = .ai
        argumentLink = nil
        argumentSession = nil
        files.stop()
        cancelProvidedLiveItems()
        showActions = false
        confirmation = nil
    }

    /// A writing command: a new run on the selection (or the passage given), put next to earlier
    /// runs in the history. A reply still being written keeps its run as it is.
    private func openWriting(_ action: AIAction, attachment: AIAttachment?) {
        let busy = ai.isGenerating
        let switching = ai.action != action || ai.command != nil
        if destination == .search { aiReturn = (section, query) }
        enterAIView()
        ai.refreshAvailability()
        feedback = nil
        guard !busy else {
            if attachment != nil {
                feedback = .warning("Stop the current response or wait for it to finish before choosing another passage.")
            } else if switching {
                feedback = .warning("Stop the current response or wait for it to finish before switching AI commands.")
            }
            focusRequest += 1
            return
        }
        startWritingRun(action)
        if let attachment {
            if attachment.text.count > AIChatModel.inputLimit {
                ai.report(Self.passageTooLong)
            } else {
                ai.attach(attachment)
                if ai.canSend { ai.send() }
            }
        } else if readsSelectionImplicitly {
            captureSelectionAndRun(startsNewRun: false)
        }
        focusRequest += 1
    }

    /// Puts the run on screen into the history and opens an empty one for `action`, bound to the
    /// app the launcher was opened from.
    func startWritingRun(_ action: AIAction) {
        cancelSelectionCapture()
        commitWritingRun()
        ai.newConversation(action: action)
        ai.open(action)
        selectionNotice = nil
        bindDestination(to: nil)
    }

    /// Binds the run on screen to the app its result goes back to: the selection's app, with its
    /// focus check, or else the app the launcher was opened from. That's `foregroundApplication`,
    /// which choosing a window for a layout never changes. OpenRay itself is never one.
    func bindDestination(to selection: SelectedTextContext?) {
        aiDestination = nil
        guard let application = selection?.application ?? foregroundApplication, !application.isTerminated,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let name =
            selection?.application != nil
            ? selection?.sourceName ?? "your app" : application.localizedName ?? "your app"
        aiDestination = RunDestination(
            conversation: ai.conversationToken, application: application, name: name,
            focusIsOriginal: selection?.application != nil ? selection?.focusIsOriginal : nil)
    }

    /// The app writing commands read from and go back to: the one the launcher was opened from,
    /// or a hotkey ran in. Never the window-layout picker's choice (re-review #6).
    var writingSourceApplication: NSRunningApplication? { foregroundApplication }
    private var writingSourceName: String { foregroundApplication?.localizedName ?? "your app" }

    /// The selection in the app OpenRay was opened from, with its app, element and range, so a
    /// result can later replace exactly it. One mechanism for writing commands, `{selection}`
    /// and AI Commands (main #13's `SelectedTextContext`). Secure fields and Secure Input refuse.
    func captureSelection() throws -> SelectedTextContext {
        if let selectionContextReader { return try selectionContextReader() }
        if let selectionReader {
            return SelectedTextContext(
                text: try selectionReader(), application: writingSourceApplication,
                sourceName: writingSourceName, validateForPaste: {})
        }
        // Another app's text: a launch inert by its own rule, or by an injected one, never reads it.
        try sideEffects.check("reading the selection in another app")
        guard windows.hasPermission else { throw SelectionReadError.accessibilityOff }
        return try SelectedTextContext.capture(from: writingSourceApplication)
    }

    /// The selection by the app's own Copy, once Accessibility saw none (work item 2). A clipboard
    /// change counts as the app's answer only while this capture is undisturbed: the panel stays
    /// up and the person doesn't type, click or copy in OpenRay. The environment's own guard and
    /// trust checks stand in for the launch's, and the live ⌘C is guarded by the process's rule.
    func copySelection(from application: NSRunningApplication?) async throws -> SelectedTextContext {
        if let selectionCopyReader { return try await selectionCopyReader(application) }
        let name = application?.localizedName ?? writingSourceName
        let session = SelectionCaptureSession()
        selectionCaptureSession?.disturb()
        selectionCaptureSession = session
        let monitoring = inputMonitoring
        let monitor = monitoring.add([.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak session] event in
            MainActor.assumeIsolated { session?.disturb() }
            return event
        }
        var environment = selectionCopyEnvironment
        environment.isUndisturbed = { [weak session] in session.map { !$0.isDisturbed } ?? false }
        environment.didFailToRestore = { [weak self] reason in self?.reportUnrestoredClipboard(reason) }
        let finish = environment.didFinish
        environment.didFinish = {
            if let monitor { monitoring.remove(monitor) }
            finish()
        }
        let text = try await clipboard.readSelectionByCopying(from: application, sourceName: name, environment: environment)
        return SelectedTextContext.copied(text, from: application, sourceName: name)
    }

    /// The selection a writing command runs on: Accessibility (or a test's stand-in) at once, then
    /// the ⌘C fallback, asynchronously, when Accessibility saw no selection. `completion` runs
    /// once, with the selection or why there's none, unless the capture is cancelled first.
    func resolveSelection(
        allowsCopy: Bool = true, _ completion: @escaping @MainActor (Result<SelectedTextContext, any Error>) -> Void
    ) {
        cancelSelectionCapture()
        do {
            completion(.success(try captureSelection()))
        } catch let error as SelectionReadError where allowsCopy && error.allowsCopyFallback {
            let application = writingSourceApplication
            readingSelectionFrom = application?.localizedName ?? writingSourceName
            selectionCaptureTask = Task { [weak self] in
                guard let self else { return }
                let result: Result<SelectedTextContext, any Error>
                do { result = .success(try await self.copySelection(from: application)) } catch { result = .failure(error) }
                guard !Task.isCancelled else { return }
                self.readingSelectionFrom = nil
                self.selectionCaptureTask = nil
                completion(result)
            }
        } catch {
            completion(.failure(error))
        }
    }

    /// Stops a ⌘C fallback still waiting, and its late-answer watch: after this, no clipboard
    /// change is read as the app's answer or put back over.
    func cancelSelectionCapture() {
        selectionCaptureSession?.disturb()
        selectionCaptureSession = nil
        selectionCaptureTask?.cancel()
        selectionCaptureTask = nil
        readingSelectionFrom = nil
    }

    /// Reads the selection and runs the writing command on screen on it. `startsNewRun` puts the
    /// run on screen away first, once the selection is known to fit; otherwise the selection goes
    /// into the run on screen. Without a selection, the passage editor says why.
    func captureSelectionAndRun(startsNewRun: Bool) {
        let token = ai.conversationToken
        resolveSelection { [weak self] result in
            guard let self, self.ai.action != .chat, !self.ai.isGenerating, self.ai.conversationToken == token else {
                return
            }
            switch result {
            case .success(let selection):
                guard selection.text.count <= AIChatModel.inputLimit else {
                    self.ai.report(Self.passageTooLong)
                    return
                }
                if startsNewRun { self.startWritingRun(self.ai.action) }
                self.attachSelection(selection)
                if self.ai.canSend { self.ai.send() }
            case .failure(let error) where error is CancellationError:
                // The person typed or clicked while the app's copy was awaited.
                self.selectionNotice = "Stopped reading the selection, so the clipboard was left as it is."
            case .failure(let error):
                self.selectionNotice = error.localizedDescription
            }
            self.focusRequest += 1
        }
    }

    /// Tests: what the next selection read returns. Nil goes back to reading the app.
    func setCapturedSelection(_ selection: SelectedTextContext?) {
        selectionContextReader = selection.map { selection in { selection } }
    }

    static let passageTooLong =
        "That passage is longer than \(AIChatModel.inputLimit.formatted()) characters. Choose a shorter one; your current work is kept."

    /// Whether a selection may be read without being asked: always in a normal launch, and in
    /// tests only through their stand-ins.
    var readsSelectionImplicitly: Bool {
        clipboard.usesGeneralPasteboard || selectionReader != nil || selectionContextReader != nil
    }

    /// Use Selection: chat attaches the selected text; a writing command runs on it as a new run,
    /// once it's known to fit. Returns whether a selection was attached at once.
    @discardableResult
    func attachSelectionFromPreviousApp(reportErrors: Bool = false) -> Bool {
        guard readsSelectionImplicitly || reportErrors else { return false }
        // A writing reply in flight keeps its passage and target.
        guard ai.action == .chat || !ai.isGenerating else { return false }
        if ai.action != .chat {
            captureSelectionAndRun(startsNewRun: true)
            return ai.attachments.contains { $0.source == .selection }
        }
        do {
            attachSelection(try captureSelection())
            return ai.attachments.contains { $0.source == .selection }
        } catch {
            if reportErrors { feedback = .error(error.localizedDescription) }
            return false
        }
    }

    /// Attaches a captured selection and, for a writing command, pins it as where the result goes.
    private func attachSelection(_ selection: SelectedTextContext) {
        let appName =
            selection.application?.localizedName ?? (selectionContextReader == nil ? previousApplicationName : selection.sourceName)
        ai.attach(AIAttachment(source: .selection, text: selection.text, appName: appName))
        selectionNotice = nil
        // A writing result goes back where its passage came from, wherever you are by then.
        if ai.action != .chat, let attached = ai.attachments.first, attached.source == .selection,
            attached.text == selection.text
        {
            aiSelectionTarget = PinnedSelection(context: selection, conversation: ai.conversationToken, attachmentID: attached.id)
            bindDestination(to: selection)
        }
    }

    /// Puts the writing run on screen into the history (other code calls it before it changes
    /// what AI shows).
    func stashWritingSession() { commitWritingRun() }

    /// Use Clipboard: chat attaches the clipboard's text; a writing command runs on it as a new
    /// run, once it's known to fit. A clipboard passage has no selection to go back over.
    func attachClipboardToAI() {
        // A writing reply in flight keeps its passage and target.
        guard ai.action == .chat || !ai.isGenerating else { return }
        guard let text = clipboard.readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            feedback = .info("There's no text on the clipboard.")
            focusRequest += 1
            return
        }
        if ai.action != .chat {
            guard text.count <= AIChatModel.inputLimit else {
                ai.report(Self.passageTooLong)
                focusRequest += 1
                return
            }
            // Anything on screen, a typed passage included, goes into the history first.
            if ai.command != nil || !ai.messages.isEmpty || !ai.attachments.isEmpty
                || !ai.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                startWritingRun(ai.command == nil ? ai.action : .rewrite)
            }
            aiSelectionTarget = nil
            selectionNotice = nil
            ai.attach(AIAttachment(source: .clipboard, text: text))
            if ai.canSend { ai.send() }
        } else {
            ai.attach(AIAttachment(source: .clipboard, text: text))
        }
        focusRequest += 1
    }

    func leaveAI() {
        let destinationReturn = aiReturn
        aiReturn = nil
        cancelSelectionCapture()
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
            // Esc leaves a submenu before it closes the panel.
            if !closeActionSubmenu() { showActions = false }
        } else if argumentSession != nil {
            cancelArguments()
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
        if deleteBackwardInArguments() { return true }
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
        if argumentSession != nil {
            moveArgumentFocus(1)
            return
        }
        let item = selectedItem
        if let item, argumentLink == nil, beginArguments(for: item) { return }
        switch item?.action {
        case .section(let target)? where section == .home && !query.isEmpty:
            store.recordUse(of: item!.id)
            navigate(to: target)
        case .provided(let ref)? where section == .home && !query.isEmpty && Self.opensScope(registry.descriptor(for: ref, in: self)):
            // Tab steps into a provider's list, as it does into a built-in scope.
            perform(item!)
        case .quicklink(let link, let argument)? where link.needsQuery && argument.isEmpty && argumentLink == nil:
            beginArgument(link)
        case .clipboard(let entry)?:
            if let text = entry.plainText {
                openAI(.chat, attachment: AIAttachment(source: .clipboard, text: text, appName: entry.sourceName))
            }
        case .file(let url)? where canEnterFilePath(url):
            enterFilePath(url)
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
        // ↑ at the top of an empty Everything recalls earlier searches.
        if recallSearchHistory(offset) { return }
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
        if section == .home && isQueryBlank { return true }
        // Any grid the selection is in, such as a provider's grid group in a list scope.
        let groups = groups
        let selected = groups.first { group in group.items.contains { $0.id == selectedID } } ?? groups.first
        return selected.flatMap { Self.columns(for: $0) } != nil
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
        // So does an alias and a space, for a command that takes arguments.
        if section == .home, destination == .search, argumentLink == nil, argumentSession == nil,
            query.last?.isWhitespace == true, beginArgumentsFromAlias(in: query)
        {
            return
        }
        // Typing over a recalled search starts a new one.
        if let cursor = historyCursor, memory.memory.history.indices.contains(cursor) ? memory.memory.history[cursor] != query : true {
            historyCursor = nil
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
                    // A query that changed again before this task started never reaches the provider.
                    guard !Task.isCancelled, let model = self, model.liveGeneration == generation,
                        let provider = model.registry.provider(id: providerID)
                    else { return }
                    // The provider's commands as the search starts: a row it builds for one of them
                    // keeps that identity even if the command is withdrawn before the row arrives.
                    let commandIDs = Set(provider.commands(in: model).map(\.id))
                    let rows = await provider.liveItems(for: term, scope: scope, in: model)
                    guard let self, !Task.isCancelled, self.liveGeneration == generation else { return }
                    // Root-search rows never become the Top Hit; see searchGroups. A row for a
                    // command keeps that identity, so it's refused rather than run unconfirmed if
                    // the command goes while the row is listed; one whose command already went
                    // during the search isn't listed at all.
                    self.providedLiveItems[providerID] = rows.compactMap { row in
                        var row = self.markingCommandIdentity(row, provider: providerID, commandIDs: commandIDs)
                        if case .provided(let ref) = row.action, ref.has(.descriptor),
                            self.registry.descriptor(for: ref, in: self) == nil
                        {
                            return nil
                        }
                        row.isLiveResult = scope == nil
                        return row
                    }
                    self.pendingLiveProviderIDs.remove(providerID)
                })
        }
    }

    /// Forgets live rows that stand for a command the catalog no longer has. Rows are marked
    /// with their command as they arrive, so this needs no new search (a provider that announces
    /// catalog changes from its own search can't start a loop).
    func dropLiveRowsForWithdrawnCommands() {
        guard !providedLiveItems.isEmpty else { return }
        var kept = providedLiveItems
        var changed = false
        for (providerID, rows) in providedLiveItems {
            let remaining = rows.filter { row in
                guard case .provided(let ref) = row.action, ref.has(.descriptor) else { return true }
                return registry.descriptor(for: ref, in: self) != nil
            }
            if remaining.count != rows.count {
                kept[providerID] = remaining
                changed = true
            }
        }
        if changed { providedLiveItems = kept }
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
