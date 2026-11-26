import Observation
import SwiftUI
import Translation

/// Translate: a scope whose search field is the text to translate, plus inline answers in root
/// search for phrasings such as "hello in german".
///
/// Translations run on this Mac with Apple Translation. They take a moment, so they arrive as
/// live rows: in root search under "Translation", after the instant results, never as the Top
/// Hit; in the scope, as its only row. A synchronous "Translate “…” to German" row also ranks
/// in root search and opens the scope. ↩ copies and ⌘↩ pastes through `AnswerDelivery`. The
/// default target and the remembered source live in `commandPreferences["translate"]`.
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
    nonisolated static let inlineRank = 600

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
    /// Asks the system to download models, from a view in the scope's preview pane.
    let downloads = TranslationDownloads()
    private var restoredSource = false

    init() { service = TranslationService() }

    init(service: TranslationService) { self.service = service }

    // MARK: Preferences

    /// The language text goes into unless a phrase names one: the saved choice, else the
    /// Mac's first language that Translation offers, else English.
    func defaultTarget(in model: LauncherModel) -> TranslationLanguage {
        if let saved = model.store.database.commandPreferences[Self.preferencesKey]?["target"],
            let language = TranslationLanguages.all.first(where: { $0.id == saved })
        {
            return language
        }
        for identifier in Locale.preferredLanguages {
            if let language = TranslationLanguages.matching(Locale.Language(identifier: identifier)) { return language }
        }
        return TranslationLanguages.english
    }

    func setDefaultTarget(_ language: TranslationLanguage, in model: LauncherModel) {
        model.store.update { $0.commandPreferences[Self.preferencesKey, default: [:]]["target"] = language.id }
    }

    private func restoreLastSource(in model: LauncherModel) {
        guard !restoredSource else { return }
        restoredSource = true
        if let saved = model.store.database.commandPreferences[Self.preferencesKey]?["lastSource"],
            let language = TranslationLanguages.all.first(where: { $0.id == saved })
        {
            service.restore(lastSource: language)
        }
    }

    private func saveLastSource(in model: LauncherModel) {
        let id = service.lastSource.id
        guard model.store.database.commandPreferences[Self.preferencesKey]?["lastSource"] != id else { return }
        model.store.update { $0.commandPreferences[Self.preferencesKey, default: [:]]["lastSource"] = id }
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
                id: "translate.inline", title: "Translate “\(request.text.truncatedForFeedback)” to \(request.target.name)",
                subtitle: "Apple Translation, on this Mac", symbol: "character.bubble", kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "open", payload: request.text,
                        arguments: Self.arguments(target: request.target, source: request.source),
                        primaryTitle: "Open in Translate", rank: Self.inlineRank, traits: [])))
        ]
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.languagesScope.id else { return [] }
        let current = scope.arguments["target"]
        return TranslationLanguages.all.map { language in
            LauncherItem(
                id: "translate.language.\(language.id)", title: language.name,
                subtitle: language.id == current ? "Current" : language.aliases.first ?? "", symbol: "globe",
                kind: .command, badge: "Language", keywords: language.aliases.joined(separator: " "),
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "language", payload: language.id, arguments: scope.arguments,
                        primaryTitle: "Translate to \(language.name)", traits: [])))
        }
    }

    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        restoreLastSource(in: model)
        let request: TranslationRequest
        if let scope {
            guard scope.id == Self.scope.id, !query.isEmpty, query.count <= TranslationParser.maximumLength else {
                return []
            }
            let target =
                scope.arguments["target"].flatMap { id in TranslationLanguages.all.first { $0.id == id } }
                ?? defaultTarget(in: model)
            let source = scope.arguments["source"].flatMap { id in TranslationLanguages.all.first { $0.id == id } }
            request = TranslationRequest(text: query, source: source, target: target)
        } else {
            guard let parsed = TranslationParser.parse(query) else { return [] }
            request = parsed
        }
        do {
            let outcome = try await service.translate(request)
            guard !Task.isCancelled else { return [] }
            saveLastSource(in: model)
            return [translationRow(outcome, inScope: scope != nil)]
        } catch let failure as TranslationFailure {
            return [failureRow(failure, request: request)]
        } catch {
            return [failureRow(.failed(error.localizedDescription), request: request)]
        }
    }

    func translationRow(_ outcome: TranslationOutcome, inScope: Bool) -> LauncherItem {
        let direction = "\(outcome.source.name) → \(outcome.target.name)\(outcome.isReversed ? " (Auto)" : "")"
        return LauncherItem(
            id: "translate.result", title: outcome.translatedText,
            subtitle: inScope ? direction : "“\(outcome.sourceText.truncatedForFeedback)” · \(direction)",
            symbol: "character.bubble", kind: .command, badge: "Translation",
            action: .provided(
                ProvidedRef(
                    provider: id, id: "translation", payload: outcome.sourceText,
                    arguments: Self.arguments(target: outcome.target, source: outcome.source),
                    copyText: outcome.translatedText, primaryTitle: "Copy Translation",
                    rank: Self.inlineRank, traits: [.paste])))
    }

    func failureRow(_ failure: TranslationFailure, request: TranslationRequest) -> LauncherItem {
        switch failure {
        case .needsDownload(let source, let target):
            let name = TranslationLanguages.all.first { $0.id == target }?.name ?? target
            return LauncherItem(
                id: "translate.download", title: "Download \(name) to translate on this Mac",
                subtitle: "Apple Translation needs this language once. Press ↩ to download it.",
                symbol: "arrow.down.circle", kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "download", payload: request.text,
                        arguments: ["source": source, "target": target], primaryTitle: "Download Language",
                        rank: Self.inlineRank, traits: [])))
        default:
            return LauncherItem(
                id: "translate.unavailable", title: failure.message,
                subtitle: "Choose another language with ⌘P.", symbol: "exclamationmark.triangle",
                kind: .command, badge: "Translate",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "chooseLanguage", payload: request.text,
                        arguments: Self.arguments(target: request.target, source: request.source),
                        primaryTitle: "Choose Language", rank: Self.inlineRank, traits: [.unavailable])))
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.scope.id else { return nil }
        let target = scope.arguments["target"].flatMap { id in TranslationLanguages.all.first { $0.id == id } }
            ?? defaultTarget(in: model)
        if isLoading {
            return ProvidedEmptyState(title: "Translating…", detail: "Into \(target.name), on this Mac.", symbol: "character.bubble")
        }
        return ProvidedEmptyState(
            title: "Translate into \(target.name)",
            detail: "Type or paste text. OpenRay detects its language and translates on this Mac. ⌘P changes the language.",
            symbol: "character.bubble")
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        switch ref.id {
        case "download":
            return ProvidedPreview(content: AnyView(TranslationDownloadHost(downloads: downloads)))
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
            guard let source = ref.arguments["source"], let target = ref.arguments["target"] else { return }
            if case .provided = model.section {
                downloads.request(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
            } else {
                // The download consent needs the Translate scope's preview pane.
                open(text: ref.payload ?? "", arguments: ["target": target], in: model)
            }
        case "chooseLanguage":
            chooseLanguage(text: ref.payload ?? model.query, arguments: ref.arguments, in: model)
        case "language":
            guard let target = ref.payload else { return }
            var arguments = ref.arguments
            arguments["target"] = target
            if let language = TranslationLanguages.all.first(where: { $0.id == target }) {
                setDefaultTarget(language, in: model)
            }
            open(text: arguments["text"] ?? "", arguments: arguments, in: model)
        default: break
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.id == "translation" ? AnswerDelivery.primaryTitle(copy: "Copy Translation", in: model) : ref.primaryTitle
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case "translation": "doc.on.doc"
        case "download": "arrow.down.circle"
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
        guard ref.id == "translation" else { return [] }
        let source = ref.payload ?? ""
        let translated = ref.copyText ?? item.title
        let arguments = ref.arguments
        return [
            ActionEntry(
                id: "translate.copySource", title: "Copy Source Text", symbol: "doc.on.doc",
                shortcut: .command("C", shift: true), key: "c", modifiers: [.command, .shift], group: .item
            ) { [weak model] in model?.copy(source) },
            ActionEntry(
                id: "translate.swap", title: "Swap Languages", symbol: "arrow.left.arrow.right",
                shortcut: .command("S"), key: "s", modifiers: .command, group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.open(text: translated, arguments: ["target": arguments["source"] ?? "", "source": arguments["target"] ?? ""], in: model)
            },
            ActionEntry(
                id: "translate.language", title: "Change Target Language…", symbol: "globe",
                shortcut: .command("P"), key: "p", modifiers: .command, group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.chooseLanguage(text: source, arguments: arguments, in: model)
            },
            ActionEntry(id: "translate.ai", title: "Continue in AI Chat", symbol: "sparkles", group: .item) { [weak model] in
                model?.openAI(.chat, prompt: "“\(source)” translates to “\(translated)”. ")
            },
        ]
    }

    /// Opens the scope with text in the field and the chosen languages.
    func open(text: String, arguments: [String: String], in model: LauncherModel) {
        var scope = Self.scope
        scope.arguments = arguments.filter { $0.key == "target" || $0.key == "source" }.filter { !$0.value.isEmpty }
        if let target = scope.arguments["target"], let language = TranslationLanguages.all.first(where: { $0.id == target }) {
            scope.title = "Translate to \(language.name)"
        }
        model.navigate(to: .provided(scope))
        model.query = text
    }

    private func chooseLanguage(text: String, arguments: [String: String], in model: LauncherModel) {
        var scope = Self.languagesScope
        scope.arguments = arguments
        scope.arguments["text"] = text
        model.navigate(to: .provided(scope))
    }

    nonisolated static func arguments(target: TranslationLanguage, source: TranslationLanguage?) -> [String: String] {
        var arguments = ["target": target.id]
        if let source { arguments["source"] = source.id }
        return arguments
    }
}

/// The pending model download, for `TranslationDownloadHost`.
@MainActor
@Observable
final class TranslationDownloads {
    private(set) var configuration: TranslationSession.Configuration?
    private(set) var status: String?

    /// Asks the system to download the models for a direction. Asking again retries.
    func request(source: Locale.Language, target: Locale.Language) {
        status = "Waiting for the download to finish…"
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    func finish(_ message: String) {
        status = message
    }
}

/// Lives in the Translate scope's preview pane, where `translationTask` can ask the person to
/// download a language. Only an explicit ↩ on the download row starts it.
struct TranslationDownloadHost: View {
    let downloads: TranslationDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: OR.Space.s2) {
            Label("Translation languages", systemImage: "arrow.down.circle")
                .font(OR.Font.headline).foregroundStyle(OR.Color.text)
            Text(
                downloads.status
                    ?? "Press ↩ to download this language. macOS asks first, and the language then works offline."
            )
            .font(OR.Font.body).foregroundStyle(OR.Color.text2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .translationTask(downloads.configuration) { @Sendable [downloads] session in
            // Off the main actor, so the framework's session never crosses isolation.
            do {
                try await session.prepareTranslation()
                await downloads.finish("Downloaded. Type again to translate.")
            } catch {
                await downloads.finish("The language didn't download. \(error.localizedDescription)")
            }
        }
    }
}
