import Observation
import SwiftUI
import Translation

/// Translate: a scope whose search field is the text to translate, plus inline answers in root
/// search for phrasings such as "hello in german".
///
/// The scope's arguments hold only what the person chose: `target`, and `source` when they
/// picked one instead of Detect Language. What detection found stays on the result row, so
/// changing the target never turns a detected language into a fixed one. Target and source
/// rows are always present, so the pickers are reachable when the scope is empty, loading,
/// failed or showing a translation.
///
/// Translations take a moment, so they arrive as live rows: in root search under
/// "Translation", after the instant results, never as the Top Hit; in the scope, above the
/// language rows. ↩ copies and ⌘↩ pastes through `AnswerDelivery`. A request that's cancelled
/// before it's used never changes where later same-language text goes.
@MainActor
final class TranslatorProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "translate", bindablePrefixes: ["translate."]) {
        TranslatorProvider()
    }

    nonisolated static let openID = "translate.open"
    nonisolated static let preferencesKey = "translate"
    /// The fixed rank of rows that answer a phrase, which skips the matcher (a translation's
    /// title never contains the query). It's below exact and prefix title matches (850 and up),
    /// so an app, file or command named like the phrase stays the Top Hit.
    nonisolated static let answerRank = 600

    static let scope = ProvidedScope(
        id: "translate", provider: "translate", title: "Translate", symbol: "character.bubble", kind: .command,
        placeholder: "Type or paste text to translate", summary: "Translate text on this Mac with Apple Translation",
        shortTitle: "Translate", itemNoun: "translation", showsPreview: true, ranksItems: false)

    static let languagesScope = ProvidedScope(
        id: "translate.languages", provider: "translate", title: "Translate To", symbol: "globe", kind: .command,
        placeholder: "Search languages", itemNoun: "language")

    var id: String { Self.registration.id }
    var providesLiveItems: Bool { true }
    var liveGroupTitle: String { "Translation" }

    let service: TranslationService
    /// Asks macOS to download a language, from a view in the scope's preview pane.
    let downloads: TranslationDownloads
    private var restoredSource = false
    /// How many finished downloads refreshed the translation they belonged to.
    private(set) var downloadRefreshes = 0

    /// The search a download belongs to: it ends when the search, the scope or the panel's
    /// showing ends.
    static func downloadContext(of model: LauncherModel) -> TranslationDownloads.Context {
        TranslationDownloads.Context(
            search: model.searchGeneration, presentation: model.presentation, scope: model.section.rawValue)
    }

    /// The app's provider: Apple Translation in a normal launch, an inert engine and no
    /// download prompts in the test host and verification mode.
    init(sideEffects: SideEffectGuard = .current) {
        service = TranslationService(engine: AppleTranslationEngine.standard(sideEffects))
        downloads = TranslationDownloads(sideEffects: sideEffects)
    }

    init(service: TranslationService, downloads: TranslationDownloads = TranslationDownloads()) {
        self.service = service
        self.downloads = downloads
    }

    // MARK: Preferences

    /// The language text goes into unless a phrase or the scope names one: the saved choice,
    /// else the Mac's first language that Translation offers, else English.
    func defaultTarget(in model: LauncherModel) -> TranslationLanguage {
        if let saved = Self.language(model.store.database.commandPreferences[Self.preferencesKey]?["target"]) {
            return saved
        }
        for identifier in Locale.preferredLanguages {
            if let language = TranslationLanguages.matching(Locale.Language(identifier: identifier)) { return language }
        }
        return TranslationLanguages.english
    }

    @discardableResult
    func setDefaultTarget(_ language: TranslationLanguage, in model: LauncherModel) -> Bool {
        model.store.update { $0.commandPreferences[Self.preferencesKey, default: [:]]["target"] = language.id }
    }

    private func restoreLastSource(in model: LauncherModel) {
        guard !restoredSource else { return }
        restoredSource = true
        if let saved = Self.language(model.store.database.commandPreferences[Self.preferencesKey]?["lastSource"]) {
            service.restore(lastSource: saved)
        }
    }

    /// Remembers a used outcome's source, in the service and the library.
    private func remember(_ outcome: TranslationOutcome, in model: LauncherModel) {
        service.remember(outcome)
        let id = service.lastSource.id
        guard model.store.database.commandPreferences[Self.preferencesKey]?["lastSource"] != id else { return }
        model.store.update { $0.commandPreferences[Self.preferencesKey, default: [:]]["lastSource"] = id }
    }

    nonisolated static func language(_ id: String?) -> TranslationLanguage? {
        id.flatMap { id in TranslationLanguages.all.first { $0.id == id } }
    }

    /// The person's choices as scope arguments: a target, and a source unless it's detected.
    nonisolated static func arguments(target: TranslationLanguage?, source: TranslationLanguage?) -> [String: String] {
        var arguments: [String: String] = [:]
        if let target { arguments["target"] = target.id }
        if let source { arguments["source"] = source.id }
        return arguments
    }

    /// Only the choices among a row's or scope's arguments.
    nonisolated static func choices(_ arguments: [String: String]) -> [String: String] {
        arguments.filter { ($0.key == "target" || $0.key == "source") && !$0.value.isEmpty }
    }

    // MARK: Commands and rows

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.openID, title: "Translate", subtitle: Self.scope.summary, kind: .command,
                symbol: "character.bubble", keywords: ["translate", "translation", "language", "languages"],
                mode: .view(.provided(Self.scope)))
        ]
    }

    /// "hello in german" offers to open the scope, ranked like an ordinary row.
    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        guard let request = TranslationParser.parse(query) else { return [] }
        return [
            LauncherItem(
                id: "translation.inline", title: "Translate “\(request.text.truncatedForFeedback)” to \(request.target.name)",
                subtitle: "Apple Translation, on this Mac", symbol: "character.bubble", kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "open", payload: request.text,
                        arguments: Self.arguments(target: request.target, source: request.source),
                        primaryTitle: "Open in Translate", rank: Self.answerRank, traits: [])))
        ]
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        switch scope.id {
        case Self.scope.id: return controls(scope.arguments, text: query, in: model)
        case Self.languagesScope.id: return languageRows(scope.arguments)
        default: return []
        }
    }

    /// The target and source rows, present in every state of the scope.
    func controls(_ arguments: [String: String], text: String, in model: LauncherModel) -> [LauncherItem] {
        let target = Self.language(arguments["target"]) ?? defaultTarget(in: model)
        let source = Self.language(arguments["source"])
        var choices = Self.choices(arguments)
        choices["text"] = text
        return [
            LauncherItem(
                id: "translation.target", title: "Translate to \(target.name)", subtitle: "⌘L changes the language",
                symbol: "globe", kind: .command, badge: "Language",
                action: .provided(
                    ProvidedRef(provider: id, id: "pickTarget", arguments: choices, primaryTitle: "Change Target Language", traits: []))),
            LauncherItem(
                id: "translation.source", title: source.map { "From \($0.name)" } ?? "From: Detect Language",
                subtitle: "⇧⌘L changes the source", symbol: "text.magnifyingglass", kind: .command, badge: "Language",
                action: .provided(
                    ProvidedRef(provider: id, id: "pickSource", arguments: choices, primaryTitle: "Change Source Language", traits: []))),
        ]
    }

    private func languageRows(_ arguments: [String: String]) -> [LauncherItem] {
        let pickingSource = arguments["pick"] == "source"
        let current = arguments[pickingSource ? "source" : "target"]
        var rows: [LauncherItem] = []
        if pickingSource {
            rows.append(
                LauncherItem(
                    id: "translation.language.detect", title: "Detect Language",
                    subtitle: current == nil ? "Current" : "Find the language from the text", symbol: "text.magnifyingglass",
                    kind: .command, badge: "Source", keywords: "automatic auto detect",
                    action: .provided(
                        ProvidedRef(provider: id, id: "language", payload: "detect", arguments: arguments, primaryTitle: "Detect Language", traits: []))))
        }
        rows += TranslationLanguages.all.map { language in
            LauncherItem(
                id: "translation.language.\(language.id)", title: language.name,
                subtitle: language.id == current ? "Current" : language.aliases.first ?? "", symbol: "globe",
                kind: .command, badge: pickingSource ? "Source" : "Language",
                keywords: language.aliases.joined(separator: " "),
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "language", payload: language.id, arguments: arguments,
                        primaryTitle: pickingSource ? "Translate from \(language.name)" : "Translate to \(language.name)",
                        traits: [])))
        }
        return rows
    }

    /// The translation above the language rows.
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.scope.id else { return nil }
        let controls = items.filter { $0.id == "translation.target" || $0.id == "translation.source" }
        let answers = items.filter { $0.id != "translation.target" && $0.id != "translation.source" }
        return [
            LauncherResultGroup(id: "translation.answer", title: nil, isLoading: model.isLoadingProvidedItems, items: answers),
            LauncherResultGroup(id: "translation.languages", title: "Languages", items: controls),
        ]
    }

    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        restoreLastSource(in: model)
        // Any new search ends a download request from an earlier one.
        downloads.cancel(unless: Self.downloadContext(of: model))
        let request: TranslationRequest
        let choices: [String: String]
        if let scope {
            guard scope.id == Self.scope.id else { return [] }
            guard !query.isEmpty, query.count <= TranslationParser.maximumLength else { return [] }
            let target = Self.language(scope.arguments["target"]) ?? defaultTarget(in: model)
            let source = Self.language(scope.arguments["source"])
            request = TranslationRequest(text: query, source: source, target: target)
            choices = Self.choices(scope.arguments)
        } else {
            guard let parsed = TranslationParser.parse(query) else { return [] }
            request = parsed
            choices = Self.arguments(target: parsed.target, source: parsed.source)
        }
        do {
            let outcome = try await service.translate(request)
            // Only a result that's still wanted may change the remembered source.
            guard !Task.isCancelled else { return [] }
            remember(outcome, in: model)
            return [translationRow(outcome, choices: choices, inScope: scope != nil)]
        } catch is CancellationError {
            return []
        } catch let failure as TranslationFailure {
            guard !Task.isCancelled else { return [] }
            return [failureRow(failure, request: request, choices: choices)]
        } catch {
            guard !Task.isCancelled else { return [] }
            return [failureRow(.failed(error.localizedDescription), request: request, choices: choices)]
        }
    }

    func translationRow(_ outcome: TranslationOutcome, choices: [String: String], inScope: Bool) -> LauncherItem {
        let detected = outcome.sourceWasDetected ? " (detected)" : ""
        let direction = "\(outcome.source.name)\(detected) → \(outcome.target.name)\(outcome.isReversed ? " (Auto)" : "")"
        var arguments = choices
        arguments["resolvedSource"] = outcome.source.id
        arguments["resolvedTarget"] = outcome.target.id
        return LauncherItem(
            id: "translation.result", title: outcome.translatedText,
            subtitle: inScope ? direction : "“\(outcome.sourceText.truncatedForFeedback)” · \(direction)",
            symbol: "character.bubble", kind: .command, badge: "Translation",
            action: .provided(
                ProvidedRef(
                    provider: id, id: "translation", payload: outcome.sourceText, arguments: arguments,
                    copyText: outcome.translatedText, primaryTitle: "Copy Translation", rank: Self.answerRank,
                    traits: [.paste])))
    }

    func failureRow(_ failure: TranslationFailure, request: TranslationRequest, choices: [String: String]) -> LauncherItem {
        var arguments = choices
        arguments["text"] = request.text
        switch failure {
        case .needsDownload(let source, let target):
            arguments["pairSource"] = source
            arguments["pairTarget"] = target
            let name = Self.language(target)?.name ?? target
            return LauncherItem(
                id: "translation.download", title: "Download \(name) to translate on this Mac",
                subtitle: "Apple Translation needs this language once. Press ↩ to download it.",
                symbol: "arrow.down.circle", kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "download", payload: request.text, arguments: arguments,
                        primaryTitle: "Download Language", rank: Self.answerRank, traits: [])))
        case .unknownSourceLanguage:
            return LauncherItem(
                id: "translation.unavailable", title: failure.message,
                subtitle: "Press ↩ to choose the source language.", symbol: "exclamationmark.triangle",
                kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "pickSource", payload: request.text, arguments: arguments,
                        primaryTitle: "Change Source Language", rank: Self.answerRank, traits: [])))
        default:
            return LauncherItem(
                id: "translation.unavailable", title: failure.message,
                subtitle: "Press ↩ to choose another language.", symbol: "exclamationmark.triangle",
                kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "pickTarget", payload: request.text, arguments: arguments,
                        primaryTitle: "Change Target Language", rank: Self.answerRank, traits: [])))
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.languagesScope.id else { return nil }
        return ProvidedEmptyState(
            title: "No languages match “\(query.truncatedForFeedback)”",
            detail: "Apple Translation offers about 20 languages on this Mac.", symbol: "globe")
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        switch ref.id {
        case "download":
            guard let source = ref.arguments["pairSource"], let target = ref.arguments["pairTarget"] else { return nil }
            return ProvidedPreview(
                content: AnyView(
                    TranslationDownloadHost(
                        downloads: downloads, pairKey: TranslationDownloads.pairKey(source: source, target: target),
                        context: Self.downloadContext(of: model))))
        case "translation":
            return ProvidedPreview(
                content: AnyView(
                    Text(item.title).font(OR.Font.reading).foregroundStyle(OR.Color.text).textSelection(.enabled)),
                metadata: [("From", ref.payload ?? ""), ("Languages", item.subtitle)])
        default:
            return nil
        }
    }

    // MARK: ↩, ⌘↩ and ⌘K

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case "open":
            open(text: ref.payload ?? "", arguments: ref.arguments, in: model)
        case "translation":
            guard let text = ref.copyText else { return }
            AnswerDelivery.primary(text, label: text, in: model)
        case "download":
            download(ref, in: model)
        case "pickTarget", "pickSource":
            choose(ref.id == "pickSource" ? "source" : "target", text: ref.arguments["text"] ?? ref.payload ?? model.query,
                arguments: ref.arguments, in: model)
        case "language":
            var arguments = Self.choices(ref.arguments)
            let picked = ref.payload ?? ""
            if ref.arguments["pick"] == "source" {
                arguments["source"] = picked == "detect" ? nil : picked
            } else {
                arguments["target"] = picked
                if let language = Self.language(picked) { setDefaultTarget(language, in: model) }
            }
            open(text: ref.arguments["text"] ?? "", arguments: arguments, in: model)
        default: break
        }
    }

    /// In the scope, asks macOS for the language; refreshes the translation once it's there.
    /// From root search, opens the scope with the same request first.
    private func download(_ ref: ProvidedRef, in model: LauncherModel) {
        guard let source = ref.arguments["pairSource"], let target = ref.arguments["pairTarget"] else { return }
        guard model.section.providedScope?.id == Self.scope.id else {
            open(text: ref.payload ?? "", arguments: ref.arguments, in: model)
            return
        }
        let context = Self.downloadContext(of: model)
        downloads.start(source: source, target: target, context: context) { [weak self, weak model] succeeded in
            // Refresh only the search the download belongs to, if it's still on screen.
            guard succeeded, let self, let model, Self.downloadContext(of: model) == context else { return }
            self.downloadRefreshes += 1
            model.refreshProvidedLiveItems()
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.id == "translation" ? AnswerDelivery.primaryTitle(copy: "Copy Translation", in: model) : ref.primaryTitle
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "translation": "doc.on.doc"
        case "download": "arrow.down.circle"
        case "pickTarget", "pickSource": "globe"
        default: "character.bubble"
        }
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard ref.id == "translation" else { return nil }
        return AnswerDelivery.secondaryTitle(copy: "Copy Translation", for: item, in: model)
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard ref.id == "translation", let text = ref.copyText else { return }
        AnswerDelivery.secondary(text, label: text, in: model)
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard ["translation", "download", "pickTarget", "pickSource"].contains(ref.id) else { return [] }
        let text = ref.arguments["text"] ?? ref.payload ?? model.query
        let choices = Self.choices(ref.arguments)
        var entries = [
            ActionEntry(
                id: "translate.pickTarget", title: "Change Target Language…", symbol: "globe",
                shortcut: .command("L"), key: "l", modifiers: .command, group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.choose("target", text: text, arguments: choices, in: model)
            },
            ActionEntry(
                id: "translate.pickSource", title: "Change Source Language…", symbol: "text.magnifyingglass",
                shortcut: .command("L", shift: true), key: "l", modifiers: [.command, .shift], group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.choose("source", text: text, arguments: choices, in: model)
            },
        ]
        guard ref.id == "translation" else { return entries }
        let source = ref.payload ?? ""
        let translated = ref.copyText ?? item.title
        let resolvedSource = Self.language(ref.arguments["resolvedSource"])
        let resolvedTarget = Self.language(ref.arguments["resolvedTarget"])
        entries.insert(
            ActionEntry(
                id: "translate.copySource", title: "Copy Source Text", symbol: "doc.on.doc",
                shortcut: .command("C", shift: true), key: "c", modifiers: [.command, .shift], group: .item
            ) { [weak model] in model?.copy(source) },
            at: 0)
        entries.insert(
            ActionEntry(
                id: "translate.swap", title: "Swap Languages", symbol: "arrow.left.arrow.right",
                shortcut: .command("S"), key: "s", modifiers: .command, group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.open(
                    text: translated, arguments: Self.arguments(target: resolvedSource, source: resolvedTarget), in: model)
            },
            at: 1)
        entries.append(
            ActionEntry(id: "translate.ai", title: "Continue in AI Chat", symbol: "sparkles", group: .item) { [weak model] in
                model?.openAI(.chat, prompt: "“\(source)” translates to “\(translated)”. ")
            })
        return entries
    }

    /// Opens the scope with text in the field and the person's choices.
    func open(text: String, arguments: [String: String], in model: LauncherModel) {
        downloads.cancel()
        var scope = Self.scope
        scope.arguments = Self.choices(arguments)
        if let target = Self.language(scope.arguments["target"]) {
            scope.title = "Translate to \(target.name)"
        }
        model.navigate(to: .provided(scope))
        model.query = text
    }

    /// Opens the language picker for the target or the source, keeping the text and choices.
    func choose(_ pick: String, text: String, arguments: [String: String], in model: LauncherModel) {
        downloads.cancel()
        var scope = Self.languagesScope
        scope.title = pick == "source" ? "Translate From" : "Translate To"
        scope.arguments = Self.choices(arguments)
        scope.arguments["pick"] = pick
        scope.arguments["text"] = text
        model.navigate(to: .provided(scope))
    }
}

/// One pending language download, asked of macOS by `TranslationDownloadHost`.
///
/// A request belongs to one language pair and one `Context`: the search, the panel's showing
/// and the scope it started in. Only a preview for that pair in that context attaches its
/// configuration, so another pair, a later search, a new showing of the panel or another scope
/// can't reopen it. Starting the same pair again in the same context does nothing, so the task
/// already asking keeps its request. The host checks the request is still current before asking
/// macOS, a completion for anything but the current request is ignored, and the provider only
/// refreshes a translation whose context is still on screen. Inert in the test host and
/// verification mode.
@MainActor
@Observable
final class TranslationDownloads {
    struct Context: Equatable, Sendable {
        var search: Int
        var presentation: Int
        var scope: String
    }

    struct Request: Equatable {
        let id: UUID
        let pairKey: String
        let context: Context
    }

    private(set) var request: Request?
    private(set) var configuration: TranslationSession.Configuration?
    private(set) var statuses: [String: String] = [:]
    @ObservationIgnored private var onFinished: (@MainActor (Bool) -> Void)?
    @ObservationIgnored let sideEffects: SideEffectGuard

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    nonisolated static func pairKey(source: String, target: String) -> String { "\(source)>\(target)" }

    func start(source: String, target: String, context: Context, onFinished: @escaping @MainActor (Bool) -> Void) {
        let key = Self.pairKey(source: source, target: target)
        guard !sideEffects.isInert else {
            statuses[key] = "Language downloads are off in this mode."
            return
        }
        // Already asking for this pair in this search: keep the running request.
        if let request, request.pairKey == key, request.context == context { return }
        request = Request(id: UUID(), pairKey: key, context: context)
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        statuses[key] = "Waiting for macOS to download the language…"
        self.onFinished = onFinished
    }

    /// The configuration to attach for a pair in a context: the current request's, or nil.
    func configuration(for pairKey: String, context: Context) -> TranslationSession.Configuration? {
        request?.pairKey == pairKey && request?.context == context ? configuration : nil
    }

    func requestID(for pairKey: String, context: Context) -> UUID? {
        request?.pairKey == pairKey && request?.context == context ? request?.id : nil
    }

    /// Whether `id` is still the request to act on.
    func isCurrent(_ id: UUID) -> Bool { request?.id == id }

    func status(for pairKey: String) -> String? { statuses[pairKey] }

    /// Ends the request `id`, unless a newer one replaced it or it was cancelled.
    func finish(id: UUID, succeeded: Bool, message: String) {
        guard let request, request.id == id else { return }
        statuses[request.pairKey] = message
        self.request = nil
        configuration = nil
        let done = onFinished
        onFinished = nil
        done?(succeeded)
    }

    func cancel() {
        request = nil
        configuration = nil
        onFinished = nil
    }

    /// Cancels a request that belongs to another search, scope or showing of the panel.
    func cancel(unless context: Context) {
        if let request, request.context != context { cancel() }
    }
}

/// Lives in the Translate scope's preview pane for one download row. It attaches the pending
/// request only when it's for this row's language pair in this search.
struct TranslationDownloadHost: View {
    let downloads: TranslationDownloads
    let pairKey: String
    let context: TranslationDownloads.Context

    var body: some View {
        let requestID = downloads.requestID(for: pairKey, context: context)
        VStack(alignment: .leading, spacing: OR.Space.s2) {
            Label("Translation languages", systemImage: "arrow.down.circle")
                .font(OR.Font.headline).foregroundStyle(OR.Color.text)
            Text(
                downloads.status(for: pairKey)
                    ?? "Press ↩ to download this language. macOS asks first, and the language then works offline."
            )
            .font(OR.Font.body).foregroundStyle(OR.Color.text2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .translationTask(downloads.configuration(for: pairKey, context: context)) { @Sendable [downloads] session in
            // Off the main actor, so the framework's session never crosses isolation.
            guard let requestID, await downloads.isCurrent(requestID) else { return }
            do {
                try await session.prepareTranslation()
                await downloads.finish(id: requestID, succeeded: true, message: "Downloaded. Translating…")
            } catch {
                await downloads.finish(
                    id: requestID, succeeded: false, message: "The language didn't download. \(error.localizedDescription)")
            }
        }
    }
}
