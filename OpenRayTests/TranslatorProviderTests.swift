import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Holds each translation until the test releases its text, and records directions.
private actor TranslationGate {
    var directions: [String] = []
    var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func hold(_ text: String) { held.insert(text) }

    func pass(_ text: String, direction: String) async {
        directions.append(direction)
        guard held.contains(text) else { return }
        await withCheckedContinuation { waiting[text, default: []].append($0) }
    }

    func release(_ text: String) {
        held.remove(text)
        for continuation in waiting.removeValue(forKey: text) ?? [] { continuation.resume() }
    }

    func isWaiting(_ text: String) -> Bool { waiting[text] != nil }
}

private struct GatedEngine: TranslationEngine {
    var availability: TranslationAvailability = .installed
    let gate = TranslationGate()

    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        availability
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        await gate.pass(text, direction: "\(source.minimalIdentifier)>\(target.minimalIdentifier)")
        return text.uppercased()
    }
}

/// Detects by text; unknown text has no language.
private struct MappedDetector: LanguageDetecting {
    var languages: [String: String] = [
        "hello": "en", "good night": "en", "bonjour": "fr", "hallo": "de", "ciao": "it",
    ]

    func dominantLanguage(of text: String) -> Locale.Language? {
        languages[text].map(Locale.Language.init(identifier:))
    }
}

@MainActor
struct TranslatorProviderTests {
    private func setUp(
        _ availability: TranslationAvailability = .installed, extra: [any CommandProvider] = [],
        downloads: TranslationDownloads = TranslationDownloads(sideEffects: SideEffectGuard(mode: .live))
    ) -> (TranslatorProvider, LauncherModel, GatedEngine) {
        let engine = GatedEngine(availability: availability)
        let provider = TranslatorProvider(
            service: TranslationService(engine: engine, detector: MappedDetector()), downloads: downloads)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider] + extra))
        return (provider, model, engine)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a condition")
    }

    private func type(_ model: LauncherModel, _ text: String) {
        model.query = text
        model.files.stop()
    }

    // MARK: Root search

    @Test func inlinePhrasesRankBelowMatchingTitles() throws {
        let (_, model, _) = setUp(extra: [TitledCommandsProvider(titles: ["Hello in German Lessons"])])
        defer { model.stop() }
        type(model, "hello in german")
        #expect(model.selectedItem?.title == "Hello in German Lessons")
        let inline = try #require(model.results.first { $0.id == "translation.inline" })
        #expect(inline.title == "Translate “hello” to German")
        guard case .provided(let ref) = inline.action else { return }
        #expect(ref.rank == TranslatorProvider.answerRank)
    }

    @Test func rootSearchTranslatesAsALiveRow() async throws {
        let (_, model, engine) = setUp()
        defer { model.stop() }
        type(model, "hello in german")
        try await waitUntil { model.groups.contains { $0.id == "live.translate" } }
        let row = try #require(model.groups.first { $0.id == "live.translate" }?.items.first)
        #expect(row.title == "HELLO")
        #expect(row.subtitle.contains("English (detected) → German"))
        #expect(await engine.gate.directions == ["en>de"])
        #expect(model.groups.first?.id != "live.translate")
    }

    @Test func theInlineRowOpensTheScopePrefilled() async throws {
        let (_, model, _) = setUp()
        defer { model.stop() }
        type(model, "good night in french")
        let inline = try #require(model.results.first { $0.id == "translation.inline" })
        model.perform(inline)
        #expect(model.section.providedScope?.id == TranslatorProvider.scope.id)
        #expect(model.section.providedScope?.arguments == ["target": "fr"])
        #expect(model.query == "good night")
        try await waitUntil { model.results.contains { $0.id == "translation.result" } }
        #expect(model.groups.first?.items.first?.id == "translation.result")
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == "translation.result")
        model.performSelected()
        #expect(model.feedback?.text.contains("GOOD NIGHT") == true)
        #expect(model.store.database.commandPreferences["translate"]?["lastSource"] == "en-US")
    }

    // MARK: Source and target

    @Test func languageRowsArePresentInEveryState() async throws {
        let (provider, model, _) = setUp()
        defer { model.stop() }
        provider.open(text: "", arguments: ["target": "de"], in: model)
        #expect(model.groups.last?.id == "translation.languages")
        #expect(model.results.map(\.title) == ["Translate to German", "From: Detect Language"])
        type(model, "qwerty")
        try await waitUntil { model.results.contains { $0.id == "translation.unavailable" } }
        #expect(model.results.contains { $0.id == "translation.target" })
        let failure = try #require(model.results.first { $0.id == "translation.unavailable" })
        let ids = model.actions(for: failure).map(\.id)
        #expect(ids.contains("translate.pickTarget") && ids.contains("translate.pickSource"))
    }

    @Test func changingTheTargetKeepsDetection() async throws {
        let (provider, model, engine) = setUp()
        defer { model.stop() }
        provider.open(text: "bonjour", arguments: ["target": "de"], in: model)
        try await waitUntil { model.results.contains { $0.id == "translation.result" } }
        let row = try #require(model.results.first { $0.id == "translation.result" })
        try #require(model.actions(for: row).first { $0.id == "translate.pickTarget" }).perform()
        #expect(model.section.providedScope?.arguments["pick"] == "target")
        #expect(model.section.providedScope?.arguments["source"] == nil)
        type(model, "ital")
        model.perform(try #require(model.results.first))
        #expect(model.section.providedScope?.arguments == ["target": "it"])
        #expect(model.query == "bonjour")
        try await waitUntil { await engine.gate.directions.count == 2 }
        #expect(await engine.gate.directions == ["fr>de", "fr>it"])
        // Detected French typed later still detects, instead of being read as English.
        type(model, "hallo")
        try await waitUntil { await engine.gate.directions.count == 3 }
        #expect(await engine.gate.directions.last == "de>it")
    }

    @Test func anUndetectableTextOffersTheSourcePicker() async throws {
        let (provider, model, engine) = setUp()
        defer { model.stop() }
        provider.open(text: "qwerty", arguments: ["target": "de"], in: model)
        try await waitUntil { model.results.contains { $0.id == "translation.unavailable" } }
        let failure = try #require(model.results.first { $0.id == "translation.unavailable" })
        model.perform(failure)
        #expect(model.section.providedScope?.id == TranslatorProvider.languagesScope.id)
        #expect(model.section.providedScope?.arguments["pick"] == "source")
        #expect(model.results.first?.title == "Detect Language")
        type(model, "french")
        model.perform(try #require(model.results.first))
        #expect(model.section.providedScope?.arguments == ["target": "de", "source": "fr"])
        #expect(model.query == "qwerty")
        try await waitUntil { await engine.gate.directions == ["fr>de"] }
        #expect(model.results.first { $0.id == "translation.source" }?.title == "From French")
    }

    // MARK: Downloads

    @Test func consentBelongsToOneSearchAndRepeatsAreIdempotent() async throws {
        let downloads = TranslationDownloads(sideEffects: SideEffectGuard(mode: .live))
        let (provider, model, _) = setUp(.needsDownload, downloads: downloads)
        defer { model.stop() }
        let japanese = TranslationDownloads.pairKey(source: "en-US", target: "ja")
        let french = TranslationDownloads.pairKey(source: "en-US", target: "fr")
        provider.open(text: "hello", arguments: ["target": "ja"], in: model)
        try await waitUntil { model.results.contains { $0.id == "translation.download" } }
        let first = TranslatorProvider.downloadContext(of: model)
        model.selectedID = "translation.download"
        model.performSelected()
        let id = try #require(downloads.requestID(for: japanese, context: first))
        #expect(downloads.configuration(for: japanese, context: first) != nil)
        #expect(downloads.configuration(for: french, context: first) == nil)
        // Pressing ↩ again keeps the request the running task belongs to.
        model.performSelected()
        #expect(downloads.requestID(for: japanese, context: first) == id)
        #expect(downloads.isCurrent(id))

        // A new search ends it: the preview can't reattach and a late answer changes nothing.
        model.query = "hello there"
        model.files.stop()
        let second = TranslatorProvider.downloadContext(of: model)
        #expect(downloads.configuration(for: japanese, context: second) == nil)
        try await waitUntil { downloads.request == nil }
        downloads.finish(id: id, succeeded: true, message: "Late")
        #expect(provider.downloadRefreshes == 0)
        #expect(downloads.status(for: japanese) != "Late")
    }

    @Test func aDownloadOnlyRefreshesTheSearchItBelongsTo() async throws {
        let downloads = TranslationDownloads(sideEffects: SideEffectGuard(mode: .live))
        let (provider, model, _) = setUp(.needsDownload, downloads: downloads)
        defer { model.stop() }
        let pair = TranslationDownloads.pairKey(source: "en-US", target: "fr")
        provider.open(text: "hello", arguments: ["target": "fr"], in: model)
        try await waitUntil { model.results.contains { $0.id == "translation.download" } }
        model.selectedID = "translation.download"
        model.performSelected()
        let id = try #require(downloads.requestID(for: pair, context: TranslatorProvider.downloadContext(of: model)))
        downloads.finish(id: id, succeeded: true, message: "Done")
        #expect(provider.downloadRefreshes == 1)
        // The refreshed search still needs the language (the fake never installs it).
        try await waitUntil { model.results.contains { $0.id == "translation.download" } }

        // Started, then the scope ends before macOS answers: no refresh of a hidden search.
        model.selectedID = "translation.download"
        model.performSelected()
        let again = try #require(downloads.requestID(for: pair, context: TranslatorProvider.downloadContext(of: model)))
        model.navigate(to: .home)
        downloads.finish(id: again, succeeded: true, message: "Done")
        #expect(provider.downloadRefreshes == 1)
    }

    @Test func theTranslationTakesTheSelectionFromTheLanguageRows() async throws {
        let (provider, model, engine) = setUp()
        defer { model.stop() }
        await engine.gate.hold("bonjour")
        provider.open(text: "bonjour", arguments: ["target": "de"], in: model)
        model.files.stop()
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == "translation.target")
        await engine.gate.release("bonjour")
        try await waitUntil { model.results.contains { $0.id == "translation.result" } }
        model.synchronizeSelection()
        #expect(model.selectedItem?.id == "translation.result")
        #expect(model.secondaryTitle(for: try #require(model.selectedItem)) != nil)

        // A language row the person chose keeps the selection.
        await engine.gate.hold("hallo")
        model.query = "hallo"
        model.files.stop()
        model.synchronizeSelection()
        model.moveSelection(1)
        #expect(model.selectedID == "translation.source")
        await engine.gate.release("hallo")
        try await waitUntil { model.results.contains { $0.title == "HALLO" } }
        model.synchronizeSelection()
        #expect(model.selectedID == "translation.source")
    }

    @Test func aRootDownloadRowKeepsTheExplicitSource() async throws {
        let (_, model, _) = setUp(.needsDownload)
        defer { model.stop() }
        type(model, "translate hallo from german to english")
        try await waitUntil { model.groups.contains { $0.id == "live.translate" } }
        let row = try #require(model.groups.first { $0.id == "live.translate" }?.items.first)
        #expect(row.id == "translation.download")
        model.perform(row)
        #expect(model.section.providedScope?.id == TranslatorProvider.scope.id)
        #expect(model.section.providedScope?.arguments == ["target": "en-US", "source": "de"])
        #expect(model.query == "hallo")
    }

    // MARK: Cancellation

    @Test func aCancelledTranslationNeverChangesTheRememberedSource() async throws {
        let (provider, model, engine) = setUp()
        defer { model.stop() }
        await engine.gate.hold("bonjour")
        await engine.gate.hold("ciao")
        provider.open(text: "bonjour", arguments: ["target": "de"], in: model)
        try await waitUntil { await engine.gate.isWaiting("bonjour") }
        type(model, "ciao")
        try await waitUntil { await engine.gate.isWaiting("ciao") }
        await engine.gate.release("ciao")
        try await waitUntil { model.results.contains { $0.title == "CIAO" } }
        #expect(provider.service.lastSource.id == "it")
        // The French request was cancelled when the text changed; finishing late changes nothing.
        await engine.gate.release("bonjour")
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.service.lastSource.id == "it")
        #expect(model.store.database.commandPreferences["translate"]?["lastSource"] == "it")
        #expect(model.results.contains { $0.title == "BONJOUR" } == false)
    }

    @Test func languagesCanBeChosenAndRemembered() throws {
        let (provider, model, _) = setUp()
        defer { model.stop() }
        provider.setDefaultTarget(try #require(TranslationLanguages.named("italian")), in: model)
        #expect(provider.defaultTarget(in: model).id == "it")
        provider.choose("target", text: "hello", arguments: [:], in: model)
        type(model, "span")
        let spanish = try #require(model.results.first)
        #expect(spanish.title == "Spanish")
        model.perform(spanish)
        #expect(model.section.providedScope?.arguments["target"] == "es")
        #expect(model.query == "hello")
        #expect(provider.defaultTarget(in: model).id == "es")
    }
}
