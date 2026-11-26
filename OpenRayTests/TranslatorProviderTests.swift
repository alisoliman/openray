import AppKit
import Foundation
import Testing

@testable import OpenRay

/// Answers instantly with an uppercased "translation" and records directions.
private actor TranslationCalls {
    var directions: [String] = []
    func append(_ direction: String) { directions.append(direction) }
}

private struct UppercasingEngine: TranslationEngine {
    var availability: TranslationAvailability = .installed
    let calls = TranslationCalls()

    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        availability
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        await calls.append("\(source.minimalIdentifier)>\(target.minimalIdentifier)")
        return text.uppercased()
    }
}

private struct EnglishDetector: LanguageDetecting {
    func dominantLanguage(of text: String) -> Locale.Language? { Locale.Language(identifier: "en") }
}

@MainActor
struct TranslatorProviderTests {
    private func setUp(_ availability: TranslationAvailability = .installed, extra: [any CommandProvider] = [])
        -> (TranslatorProvider, LauncherModel, UppercasingEngine)
    {
        let engine = UppercasingEngine(availability: availability)
        let provider = TranslatorProvider(service: TranslationService(engine: engine, detector: EnglishDetector()))
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()),
            pasteboard: NSPasteboard.withUniqueName(), registry: CommandRegistry(providers: [provider] + extra))
        return (provider, model, engine)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a condition")
    }

    @Test func inlinePhrasesRankBelowMatchingTitles() throws {
        let (_, model, _) = setUp(extra: [TitledCommandsProvider(titles: ["Hello in German Lessons"])])
        defer { model.stop() }
        model.query = "hello in german"
        model.files.stop()
        #expect(model.selectedItem?.title == "Hello in German Lessons")
        let inline = try #require(model.results.first { $0.id == "translate.inline" })
        #expect(inline.title == "Translate “hello” to German")
        guard case .provided(let ref) = inline.action else {
            Issue.record("The inline row is a provider row")
            return
        }
        #expect(ref.rank == TranslatorProvider.inlineRank)
    }

    @Test func rootSearchTranslatesAsALiveRow() async throws {
        let (_, model, engine) = setUp()
        defer { model.stop() }
        model.query = "hello in german"
        model.files.stop()
        try await waitUntil { model.groups.contains { $0.id == "live.translate" } }
        let row = try #require(model.groups.first { $0.id == "live.translate" }?.items.first)
        #expect(row.title == "HELLO")
        #expect(row.subtitle.contains("English → German"))
        #expect(await engine.calls.directions == ["en>de"])
        #expect(model.groups.first?.id != "live.translate")
    }

    @Test func theInlineRowOpensTheScopePrefilled() async throws {
        let (_, model, _) = setUp()
        defer { model.stop() }
        model.query = "good night in french"
        model.files.stop()
        let inline = try #require(model.results.first { $0.id == "translate.inline" })
        model.perform(inline)
        #expect(model.section.providedScope?.id == TranslatorProvider.scope.id)
        #expect(model.section.providedScope?.arguments["target"] == "fr")
        #expect(model.query == "good night")
        try await waitUntil { model.results.contains { $0.id == "translate.result" } }
        let row = try #require(model.results.first { $0.id == "translate.result" })
        #expect(row.title == "GOOD NIGHT")
        model.selectedID = row.id
        model.performSelected()
        #expect(model.feedback?.text.contains("GOOD NIGHT") == true)
        #expect(model.store.database.commandPreferences["translate"]?["lastSource"] == "en-US")
    }

    @Test func missingModelsOfferADownload() async throws {
        let (provider, model, _) = setUp(.needsDownload)
        defer { model.stop() }
        provider.open(text: "hello", arguments: ["target": "ja"], in: model)
        try await waitUntil { model.results.contains { $0.id == "translate.download" } }
        let row = try #require(model.results.first { $0.id == "translate.download" })
        #expect(row.title.contains("Japanese"))
        #expect(provider.downloads.configuration == nil)
        model.selectedID = row.id
        model.performSelected()
        #expect(provider.downloads.configuration?.target?.minimalIdentifier == "ja")
    }

    @Test func languagesCanBeChosenAndRemembered() throws {
        let (provider, model, _) = setUp()
        defer { model.stop() }
        provider.setDefaultTarget(try #require(TranslationLanguages.named("italian")), in: model)
        #expect(provider.defaultTarget(in: model).id == "it")
        var scope = TranslatorProvider.languagesScope
        scope.arguments = ["text": "hello"]
        model.navigate(to: .provided(scope))
        model.query = "span"
        model.files.stop()
        let spanish = try #require(model.results.first)
        #expect(spanish.title == "Spanish")
        model.perform(spanish)
        #expect(model.section.providedScope?.arguments["target"] == "es")
        #expect(model.query == "hello")
        #expect(provider.defaultTarget(in: model).id == "es")
    }
}
