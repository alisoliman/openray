import Foundation

/// The calculator's commands, answer rows, history and currency rates.
///
/// Root search and the Calculator scope show one answer for the query. `LauncherModel` builds
/// it from `answer(for:in:)`: an unambiguous answer ("2 + 3", "5pm ldn in sf") is the
/// calculator card on top; a words-only one ("time", "today") is an ordinary row that never
/// takes the Top Hit, and while search results are still arriving its ↩ waits for them, so a
/// file or app named like the word gets ↩ instead. Each search's answer is a snapshot: the card,
/// ↩, ⌘↩ and the history all use the value that was shown. ↩ copies and ⌘↩ pastes through
/// `AnswerDelivery`, and both record the calculation in `LibraryDatabase.calculatorHistory`.
@MainActor
final class CalculatorProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "calculator", bindablePrefixes: ["calculator."]
    ) { CalculatorProvider() }

    /// The answer row's id when it leads root search as the calculator card.
    nonisolated static let answerID = "calculation"
    /// The answer row's id when the query is only words and the answer is an ordinary row.
    nonisolated static let wordAnswerID = "calculation.answer"

    nonisolated static let historyID = "calculator.history"
    nonisolated static let refreshID = "calculator.refreshCurrencies"
    /// History rows per page, under the launcher's 100-row scope cap with room for paging rows.
    nonisolated static let historyPageSize = 98
    /// How long ↩ on a words-only answer waits for pending search results.
    nonisolated static let pendingSearchWait: Duration = .milliseconds(800)
    /// How often an open launcher checks whether opted-in rates are due.
    nonisolated static let staleCheckInterval: TimeInterval = 3_600

    static let historyScope = ProvidedScope(
        id: historyID, provider: "calculator", title: "Calculator History", symbol: "clock.arrow.circlepath",
        kind: .calculator, placeholder: "Search past calculations",
        summary: "Answers you copied or pasted in the last three months", shortTitle: "History",
        itemNoun: "calculation")

    /// `commandPreferences` keys.
    nonisolated static let preferencesKey = "calculator"
    nonisolated static let currencyRatesKey = "currencyRates"
    nonisolated static let pixelsPerEmKey = "pixelsPerEm"

    var id: String { Self.registration.id }

    /// The opt-in daily reference rates. Off until the owner turns them on in Settings.
    let rates: CurrencyRateStore
    /// Only the app's provider in a normal launch sets `CalculatorSettings`.
    private let publishesSettings: Bool
    private let now: () -> Date
    private var isConfigured = false
    private var lastStaleCheck: Date?
    private var snapshot: (key: SnapshotKey, calculation: Calculation?)?
    private var pendingActivation: Task<Void, Never>?

    /// What makes an answer current: the query, the search it belongs to and the settings.
    private struct SnapshotKey: Equatable {
        var query: String
        var search: Int
        var presentation: Int
        var rates: Date?
        var pixelsPerEm: Double
    }

    /// The app's provider. In the test host and verification mode it neither reads the saved
    /// rates nor fetches new ones.
    init(sideEffects: SideEffectGuard = .current) {
        if sideEffects.isInert {
            rates = CurrencyRateStore(provider: InertRateProvider(sideEffects: sideEffects), cache: CurrencyRateCache(fileURL: nil))
            publishesSettings = false
        } else {
            rates = CurrencyRateStore()
            publishesSettings = true
        }
        now = { Date() }
    }

    init(rates: CurrencyRateStore, now: @escaping () -> Date = { Date() }) {
        self.rates = rates
        publishesSettings = false
        self.now = now
    }

    // MARK: Settings

    static func currencyRatesEnabled(in database: LibraryDatabase) -> Bool {
        database.commandPreferences[preferencesKey]?[currencyRatesKey] == "on"
    }

    static func pixelsPerEm(in database: LibraryDatabase) -> Double {
        database.commandPreferences[preferencesKey]?[pixelsPerEmKey].flatMap(Double.init)
            .map { min(max($0, 8), 32) } ?? 16
    }

    /// Turns the daily rates on or off, saves the choice, re-registers hotkeys for the
    /// Refresh Currencies command it adds or removes, and fetches when rates are due.
    func setCurrencyRates(_ enabled: Bool, in model: LauncherModel) {
        guard model.store.update({
            $0.commandPreferences[Self.preferencesKey, default: [:]][Self.currencyRatesKey] = enabled ? "on" : "off"
        }) else {
            model.feedback = .error(model.store.errorMessage ?? "Couldn't save the setting.")
            return
        }
        rates.isEnabled = enabled
        publish(in: model)
        model.commandCatalogDidChange()
        if enabled { refresh(in: model, force: false) }
    }

    func setPixelsPerEm(_ pixels: Double, in model: LauncherModel) {
        guard model.store.update({
            $0.commandPreferences[Self.preferencesKey, default: [:]][Self.pixelsPerEmKey] = Calculator.format(pixels)
        }) else {
            model.feedback = .error(model.store.errorMessage ?? "Couldn't save the setting.")
            return
        }
        publish(in: model)
    }

    /// Fetches rates in the background; `force` is Refresh Currencies.
    func refresh(in model: LauncherModel, force: Bool) {
        Task { [weak self, weak model] in
            guard let self else { return }
            if force { await self.rates.refresh() } else { await self.rates.refreshIfStale() }
            if let model { self.publish(in: model) }
        }
    }

    /// What calculations see: this provider's clock, the rates when they're on, and the rem size.
    func context(in model: LauncherModel) -> CalculatorContext {
        configure(model)
        checkForStaleRates(in: model)
        return CalculatorContext(
            now: now(), currencyRates: rates.activeRates, pixelsPerEm: Self.pixelsPerEm(in: model.store.database))
    }

    /// While the launcher is in use, checks at most hourly whether opted-in rates are due.
    private func checkForStaleRates(in model: LauncherModel) {
        guard rates.isEnabled, !rates.isRefreshing, rates.isStale else { return }
        let date = now()
        if let lastStaleCheck, date.timeIntervalSince(lastStaleCheck) < Self.staleCheckInterval { return }
        lastStaleCheck = date
        refresh(in: model, force: false)
    }

    /// Reads the saved choice the first time the launcher asks, fetches if rates are due, and
    /// drops expired history.
    private func configure(_ model: LauncherModel) {
        guard !isConfigured else { return }
        isConfigured = true
        rates.isEnabled = Self.currencyRatesEnabled(in: model.store.database)
        publish(in: model)
        if rates.isEnabled {
            lastStaleCheck = now()
            refresh(in: model, force: false)
        }
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            self.pruneHistory(in: model)
        }
    }

    private func publish(in model: LauncherModel) {
        guard publishesSettings else { return }
        CalculatorSettings.publish(
            .init(currencyRates: rates.activeRates, pixelsPerEm: Self.pixelsPerEm(in: model.store.database)))
    }

    // MARK: Answers

    /// The answer for the current search, computed once: until the query, the search, the
    /// panel's showing, the rates or the rem size change, the same value is shown, copied,
    /// pasted and recorded.
    func answer(for query: String, in model: LauncherModel) -> Calculation? {
        let context = context(in: model)
        let key = SnapshotKey(
            query: query, search: model.searchGeneration, presentation: model.presentation,
            rates: context.currencyRates?.fetchedAt, pixelsPerEm: context.pixelsPerEm)
        if let snapshot, snapshot.key == key { return snapshot.calculation }
        let calculation = Calculator.evaluate(query, context: context)
        snapshot = (key, calculation)
        return calculation
    }

    /// The answer row for a calculation. Its ref carries the typed expression; actions read the
    /// search's snapshot, so they use the value the row shows.
    static func answerItem(for calculation: Calculation) -> LauncherItem {
        LauncherItem(
            id: calculation.isAmbiguous ? wordAnswerID : answerID, title: calculation.result,
            subtitle: calculation.expression, symbol: "equal", kind: .calculator, badge: "Calculator",
            action: .provided(
                ProvidedRef(
                    provider: registration.id, id: "answer", payload: calculation.expression,
                    copyText: calculation.value, primaryTitle: "Copy Answer", traits: [.paste])))
    }

    /// The calculation behind an answer row.
    func calculation(for ref: ProvidedRef, in model: LauncherModel) -> Calculation? {
        guard ref.id == "answer", let expression = ref.payload else { return nil }
        return answer(for: expression, in: model)
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        configure(model)
        var commands = [
            CommandDescriptor(
                id: Self.historyID, title: "Calculator History", subtitle: Self.historyScope.summary,
                kind: .calculator, symbol: "clock.arrow.circlepath",
                keywords: ["calculator", "history", "past calculations", "answers"],
                mode: .view(.provided(Self.historyScope)))
        ]
        if rates.isEnabled {
            commands.append(
                CommandDescriptor(
                    id: Self.refreshID, title: "Refresh Currencies", subtitle: ratesSummary,
                    kind: .calculator, symbol: "arrow.clockwise",
                    keywords: ["currency", "exchange rates", "ECB", "calculator"], mode: .noView))
        }
        return commands
    }

    /// "ECB rates for Nov 25, 2026", or why there are none.
    var ratesSummary: String {
        guard let table = rates.table else { return "Daily reference rates from the European Central Bank" }
        return "\(table.source) rates for \(table.publishedLabel(locale: .autoupdatingCurrent))"
    }

    // MARK: History scope

    /// The history within its three months, newest first.
    func history(in model: LauncherModel) -> CalculatorHistory {
        var history = CalculatorHistory(records: model.store.database.calculatorHistory)
        history.prune(now: now())
        return history
    }

    /// Saves the history without expired entries, when any have expired.
    @discardableResult
    func pruneHistory(in model: LauncherModel) -> Bool {
        let kept = history(in: model).records
        guard kept.count != model.store.database.calculatorHistory.count else { return true }
        return model.store.update { $0.calculatorHistory = kept }
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.historyID else { return [] }
        // Opening History directly also loads settings and drops expired entries.
        configure(model)
        return historyItems(in: model, query: query, page: scope.arguments["page"].flatMap(Int.init) ?? 0)
    }

    /// History rows. Browsing pages through every kept entry, with rows for newer and older
    /// pages; a search looks through all of them.
    func historyItems(in model: LauncherModel, query: String = "", page: Int = 0) -> [LauncherItem] {
        let today = now()
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        relative.dateTimeStyle = .named
        let history = history(in: model)
        let entries = query.isEmpty ? history.entries : history.matching(query)
        let pages = max(1, (entries.count + Self.historyPageSize - 1) / Self.historyPageSize)
        let page = query.isEmpty ? min(max(page, 0), pages - 1) : 0
        let shown = query.isEmpty
            ? Array(entries.dropFirst(page * Self.historyPageSize).prefix(Self.historyPageSize))
            : Array(entries.prefix(Self.historyPageSize))
        var items = shown.map { entry in
            LauncherItem(
                id: "calculator-history.\(entry.id.uuidString)", title: entry.result, subtitle: entry.expression,
                symbol: "equal", kind: .calculator, badge: relative.localizedString(for: entry.date, relativeTo: today),
                keywords: "\(entry.expression) \(entry.value)",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "history", payload: entry.id.uuidString, copyText: entry.value,
                        primaryTitle: "Copy Answer", traits: [.paste, .delete])))
        }
        if query.isEmpty, page > 0 {
            items.insert(pageItem(page - 1, title: "Newer Calculations", symbol: "chevron.up"), at: 0)
        }
        if query.isEmpty, page < pages - 1 {
            items.append(pageItem(page + 1, title: "Older Calculations", symbol: "chevron.down"))
        }
        return items
    }

    private func pageItem(_ page: Int, title: String, symbol: String) -> LauncherItem {
        LauncherItem(
            id: "calculator-history-page.\(page)", title: title, subtitle: "Page \(page + 1)", symbol: symbol,
            kind: .calculator, badge: "History",
            action: .provided(ProvidedRef(provider: id, id: "historyPage", payload: "\(page)", primaryTitle: "Show \(title)", traits: [])))
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.historyID else { return nil }
        if query.isEmpty {
            return ProvidedEmptyState(
                title: "No calculations yet",
                detail: "Answers you copy or paste from the calculator stay here for three months.",
                symbol: "clock.arrow.circlepath")
        }
        return ProvidedEmptyState(
            title: "No calculations match “\(query.truncatedForFeedback)”",
            detail: "Search by expression or answer.", symbol: "clock.arrow.circlepath")
    }

    func itemNoun(for ref: ProvidedRef) -> String { "Calculation" }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        guard ref.id == "history", let payload = ref.payload, let id = UUID(uuidString: payload) else { return nil }
        return .library { $0.calculatorHistory.removeAll { $0.id == id } }
    }

    // MARK: ↩, ⌘↩ and ⌘K

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.refreshID:
            model.store.recordUse(of: item.id)
            guard rates.isEnabled else {
                model.feedback = .info("Turn on daily currency rates in Settings › Calculator first.")
                return
            }
            model.feedback = .working("Refreshing currencies…")
            Task { [weak self, weak model] in
                guard let self, let model else { return }
                await self.rates.refresh()
                self.publish(in: model)
                if let error = self.rates.lastError {
                    model.feedback = .error(error)
                } else {
                    model.toast("Updated to \(self.ratesSummary)")
                }
            }
        case "answer":
            activate(item, ref: ref, secondary: false, in: model)
        case "history":
            guard let text = ref.copyText else { return }
            AnswerDelivery.primary(text, label: item.title, in: model)
        case "historyPage":
            var scope = Self.historyScope
            scope.arguments = ["page": ref.payload ?? "0"]
            model.navigate(to: .provided(scope))
        default: break
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard ref.id == "answer" || ref.id == "history" else { return ref.primaryTitle }
        return AnswerDelivery.primaryTitle(copy: "Copy Answer", in: model)
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "answer", "history": "doc.on.doc"
        case "historyPage": "arrow.right.circle"
        default: nil
        }
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard ref.id == "answer" || ref.id == "history" else { return nil }
        return AnswerDelivery.secondaryTitle(copy: "Copy Answer", for: item, in: model)
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case "answer":
            activate(item, ref: ref, secondary: true, in: model)
        case "history":
            guard let text = ref.copyText else { return }
            AnswerDelivery.secondary(text, label: item.title, in: model)
        default: break
        }
    }

    // MARK: Words-only answers while search is pending

    /// Whether a words-only answer is only first because other results haven't arrived yet.
    static func isProvisional(_ item: LauncherItem, in model: LauncherModel) -> Bool {
        item.id == wordAnswerID && !model.selectionMovedByHand && isSearchPending(model)
    }

    static func isSearchPending(_ model: LauncherModel) -> Bool {
        model.files.isSearching || model.isLoadingProvidedItems
    }

    /// ↩ and ⌘↩ on an answer. A words-only answer that was only selected because nothing else
    /// had arrived waits, up to `pendingSearchWait`, for search to settle, then acts on whatever
    /// is selected: a file or app named like the word if one arrived, else the answer.
    private func activate(_ item: LauncherItem, ref: ProvidedRef, secondary: Bool, in model: LauncherModel) {
        guard Self.isProvisional(item, in: model) else {
            deliver(ref, secondary: secondary, in: model)
            return
        }
        guard pendingActivation == nil else { return }
        let search = model.searchGeneration
        pendingActivation = Task { [weak self, weak model] in
            let deadline = ContinuousClock.now.advanced(by: Self.pendingSearchWait)
            while let model, Self.isSearchPending(model), ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self else { return }
            self.pendingActivation = nil
            guard let model, model.searchGeneration == search, !Task.isCancelled else { return }
            model.synchronizeSelection()
            guard let selected = model.selectedItem else { return }
            if selected.id == Self.wordAnswerID, case .provided(let ref) = selected.action {
                self.deliver(ref, secondary: secondary, in: model)
            } else if secondary {
                model.paste(selected)
            } else {
                model.perform(selected)
            }
        }
    }

    private func deliver(_ ref: ProvidedRef, secondary: Bool, in model: LauncherModel) {
        guard let calculation = calculation(for: ref, in: model) else { return }
        let delivered =
            secondary
            ? AnswerDelivery.secondary(calculation.value, label: calculation.value, in: model)
            : AnswerDelivery.primary(calculation.value, label: calculation.value, in: model)
        if delivered { record(calculation, in: model) }
    }

    // MARK: Actions

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        switch ref.id {
        case "answer":
            guard let calculation = calculation(for: ref, in: model) else { return [] }
            return answerActions(calculation, in: model)
        case "history":
            return historyActions(item, ref: ref, in: model)
        default:
            return []
        }
    }

    private func answerActions(_ calculation: Calculation, in model: LauncherModel) -> [ActionEntry] {
        var entries = [
            ActionEntry(
                id: "calculator.putAnswer", title: "Put Answer in Search Bar", symbol: "text.cursor",
                shortcut: .command("↩", shift: true), key: .return, modifiers: [.command, .shift], group: .item
            ) { [weak model] in model?.query = calculation.value }
        ]
        if let swap = calculation.swapQuery {
            entries.append(
                ActionEntry(
                    id: "calculator.swap", title: "Swap Units", symbol: "arrow.left.arrow.right",
                    shortcut: .command("S"), key: "s", modifiers: .command, group: .item
                ) { [weak model] in model?.query = swap })
        }
        entries.append(
            ActionEntry(
                id: "calculator.copyQuestion", title: "Copy Question and Answer", symbol: "equal.square",
                shortcut: KeyShortcut(["⌥", "⇧", "⌘", "C"]), key: "c", modifiers: [.option, .shift, .command],
                group: .item
            ) { [weak self, weak model] in
                guard let model else { return }
                if model.copy("\(calculation.expression) = \(calculation.result)") { self?.record(calculation, in: model) }
            })
        if calculation.conversion != nil {
            entries.append(
                ActionEntry(id: "copyUnit", title: "Copy with Unit", symbol: "doc.on.doc", group: .item) {
                    [weak self, weak model] in
                    guard let model else { return }
                    // Full precision, as ↩ copies, with the unit the card shows.
                    let symbol = calculation.conversion?.target.symbol ?? ""
                    if model.copy("\(calculation.value) \(symbol)") { self?.record(calculation, in: model) }
                })
        } else if calculation.result != calculation.value {
            entries.append(
                ActionEntry(
                    id: "calculator.copyShown", title: "Copy “\(calculation.result.truncatedForFeedback)”",
                    symbol: "doc.on.doc", shortcut: KeyShortcut(["⌥", "⌘", "C"]), key: "c",
                    modifiers: [.option, .command], group: .item
                ) { [weak self, weak model] in
                    guard let model else { return }
                    if model.copy(calculation.result) { self?.record(calculation, in: model) }
                })
        }
        entries.append(
            ActionEntry(id: "copyExpression", title: "Copy Expression", symbol: "function", group: .item) {
                [weak model] in model?.copy(calculation.expression)
            })
        // The related-unit chips, one entry each, copying the plain value as ↩ does.
        for quantity in calculation.conversion?.related ?? [] {
            let label = "\(quantity.value) \(quantity.symbol)"
            entries.append(
                ActionEntry(
                    id: "copyRelated.\(quantity.symbol)", title: "Copy \(label)", symbol: "doc.on.doc", group: .item
                ) { [weak model] in model?.copy(quantity.copyValue) })
        }
        entries.append(
            ActionEntry(id: "calculator.showHistory", title: "Show History", symbol: "clock.arrow.circlepath", group: .item) {
                [weak model] in model?.navigate(to: .provided(Self.historyScope))
            })
        if calculation.kind == .currency, rates.isEnabled {
            entries.append(
                ActionEntry(id: "calculator.refresh", title: "Refresh Currencies", symbol: "arrow.clockwise", group: .item) {
                    [weak self, weak model] in
                    guard let self, let model else { return }
                    self.refresh(in: model, force: true)
                    model.toast("Refreshing currencies…")
                })
        }
        return entries
    }

    private func historyActions(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        let answer = ref.copyText ?? item.title
        let question = item.subtitle
        return [
            ActionEntry(
                id: "calculator.putAnswer", title: "Put Answer in Search Bar", symbol: "text.cursor",
                shortcut: .command("↩", shift: true), key: .return, modifiers: [.command, .shift], group: .item
            ) { [weak model] in Self.search(answer, in: model) },
            ActionEntry(id: "calculator.putQuestion", title: "Calculate Again", symbol: "arrow.uturn.backward", group: .item) {
                [weak model] in Self.search(question, in: model)
            },
            ActionEntry(
                id: "calculator.copyQuestion", title: "Copy Question and Answer", symbol: "equal.square",
                shortcut: KeyShortcut(["⌥", "⇧", "⌘", "C"]), key: "c", modifiers: [.option, .shift, .command],
                group: .item
            ) { [weak model] in model?.copy("\(question) = \(item.title)") },
            ActionEntry(id: "calculator.clearHistory", title: "Clear History…", symbol: "trash", group: .organize, isDestructive: true) {
                [weak self, weak model] in
                guard let self, let model else { return }
                self.confirmClear(in: model)
            },
        ]
    }

    /// Leaves History for root search with `text` in the field.
    private static func search(_ text: String, in model: LauncherModel?) {
        guard let model else { return }
        model.navigate(to: .home)
        model.query = text
    }

    func confirmClear(in model: LauncherModel) {
        let count = model.store.database.calculatorHistory.count
        model.confirmation = .provided(
            ProvidedConfirmation(
                id: "calculator.clearHistory",
                CommandConfirmation(
                    question: "Clear Calculator History?",
                    detail: "\(count) calculation\(count == 1 ? "" : "s") will be removed.",
                    confirmTitle: "Clear History", symbol: "trash")
            ) { [weak model] in
                guard let model else { return }
                if model.store.update({ $0.calculatorHistory = [] }) {
                    model.toast("Cleared Calculator History")
                } else {
                    model.feedback = .error(model.store.errorMessage ?? "Couldn't clear the history.")
                }
            })
    }

    /// Keeps a copied or pasted answer in the history, dropping expired entries in the same save.
    func record(_ calculation: Calculation, in model: LauncherModel) {
        var history = CalculatorHistory(records: model.store.database.calculatorHistory)
        let date = now()
        history.add(calculation, at: date)
        history.prune(now: date)
        model.store.update { $0.calculatorHistory = history.records }
    }
}

extension LauncherItem {
    /// The calculation a calculator row shows: the provider's answer row (the search's
    /// snapshot), or a built-in `.calculation`. Nil for every other row.
    @MainActor func calculatorAnswer(in model: LauncherModel) -> Calculation? {
        switch action {
        case .calculation(let calculation): return calculation
        case .provided(let ref) where ref.provider == CalculatorProvider.registration.id:
            let provider = model.registry.provider(id: ref.provider) as? CalculatorProvider
            return provider?.calculation(for: ref, in: model) ?? ref.payload.flatMap { Calculator.evaluate($0) }
        default: return nil
        }
    }
}
