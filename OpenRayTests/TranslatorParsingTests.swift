import Foundation
import Testing

@testable import OpenRay

struct TranslatorParsingTests {
    @Test(arguments: [
        ("hello in german", "hello", nil, "de"),
        ("good night into french", "good night", nil, "fr"),
        ("Hello in German", "Hello", nil, "de"),
        ("translate bonjour to english", "bonjour", nil, "en-US"),
        ("translate bonjour into English", "bonjour", nil, "en-US"),
        ("translate hallo from german to english", "hallo", "de", "en-US"),
        ("how do you say thank you in japanese", "thank you", nil, "ja"),
        ("how to say good morning in spanish", "good morning", nil, "es"),
        ("\"made in china\" in spanish", "made in china", nil, "es"),
        ("where is the station in italian?", "where is the station", nil, "it"),
        ("hello in deutsch", "hello", nil, "de"),
        ("thanks in español", "thanks", nil, "es"),
        ("thanks in espanol", "thanks", nil, "es"),
        ("hola in brazilian portuguese", "hola", nil, "pt-BR"),
        ("hi in portug", "hi", nil, "pt-BR"),
        ("good luck in mandarin", "good luck", nil, "zh-Hans"),
        ("good luck in traditional chinese", "good luck", nil, "zh-Hant"),
        ("cheers in british english", "cheers", nil, "en-GB"),
    ])
    func parsesInlinePhrasings(input: String, text: String, source: String?, target: String) throws {
        let request = try #require(TranslationParser.parse(input), "\(input)")
        #expect(request.text == text)
        #expect(request.source?.id == source)
        #expect(request.target.id == target)
    }

    @Test(arguments: [
        "hello in de", "hello in fr", "made in china", "files in documents", "in german", "time in tokyo",
        "10 km in mi", "hello", "translate", "\"\" in german", "123 in german", "hi in por",
    ])
    func ignoresOtherInput(_ input: String) {
        #expect(TranslationParser.parse(input) == nil)
    }

    @Test func longTextIsIgnored() {
        let long = String(repeating: "word ", count: 120) + "in german"
        #expect(TranslationParser.parse(long) == nil)
    }

    @Test func languageNamesNeedThreeLetters() {
        #expect(TranslationLanguages.named("de") == nil)
        #expect(TranslationLanguages.named("ger") == nil)
        #expect(TranslationLanguages.named("germa")?.id == "de")
        #expect(TranslationLanguages.named("Français")?.id == "fr")
        #expect(TranslationLanguages.named("日本語")?.id == "ja")
    }

    @Test func detectedLanguagesMapToOfferedOnes() {
        #expect(TranslationLanguages.matching(Locale.Language(identifier: "pt-PT"))?.id == "pt-BR")
        #expect(TranslationLanguages.matching(Locale.Language(identifier: "en"))?.id == "en-US")
        #expect(TranslationLanguages.matching(Locale.Language(identifier: "zh-Hant"))?.id == "zh-Hant")
        #expect(TranslationLanguages.matching(Locale.Language(identifier: "zh"))?.id == "zh-Hans")
        #expect(TranslationLanguages.matching(Locale.Language(identifier: "sw")) == nil)
    }

    @Test func naturalLanguageDetectsALongSentence() {
        let detector = NaturalLanguageDetector()
        let french = detector.dominantLanguage(of: "Bonjour, comment allez-vous aujourd'hui ? Je suis très content de vous voir.")
        #expect(french?.languageCode?.identifier == "fr")
        #expect(detector.dominantLanguage(of: "") == nil)
    }
}

/// Detects whatever it was told, keyed by text.
private struct FakeDetector: LanguageDetecting {
    var languages: [String: String]

    func dominantLanguage(of text: String) -> Locale.Language? {
        languages[text].map(Locale.Language.init(identifier:))
    }
}

/// Uppercases text and records each direction it was asked for.
private actor FakeEngineLog {
    var calls: [String] = []
    func append(_ call: String) { calls.append(call) }
}

private struct FakeEngine: TranslationEngine {
    var availability: TranslationAvailability = .installed
    let log = FakeEngineLog()

    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        availability
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        await log.append("\(source.minimalIdentifier)>\(target.minimalIdentifier)")
        return text.uppercased()
    }
}

@MainActor
struct TranslationServiceTests {
    private let detector = FakeDetector(languages: [
        "hello": "en", "hallo": "de", "bonjour": "fr", "guten tag": "de", "xyz": "und",
    ])

    private func request(_ text: String, to target: String, from source: String? = nil) -> TranslationRequest {
        TranslationRequest(
            text: text, source: source.flatMap(TranslationLanguages.named), target: TranslationLanguages.named(target)!)
    }

    @Test func detectsTheSourceLanguage() async throws {
        let engine = FakeEngine()
        let service = TranslationService(engine: engine, detector: detector)
        let outcome = try await service.translate(request("hello", to: "german"))
        service.remember(outcome)
        #expect(outcome.translatedText == "HELLO")
        #expect(outcome.source.id == "en-US")
        #expect(outcome.target.id == "de")
        #expect(outcome.isReversed == false)
        #expect(await engine.log.calls == ["en>de"])
    }

    @Test func textAlreadyInTheTargetGoesToTheLastSource() async throws {
        let engine = FakeEngine()
        let service = TranslationService(engine: engine, detector: detector)
        // English is the default last source.
        let first = try await service.translate(request("hallo", to: "german"))
        service.remember(first)
        #expect(first.isReversed)
        #expect(first.target.id == "en-US")
        // French becomes the last source once remembered, so German text now goes to French.
        let french = try await service.translate(request("bonjour", to: "german"))
        #expect(service.lastSource.id == "en-US")
        service.remember(french)
        #expect(service.lastSource.id == "fr")
        let second = try await service.translate(request("guten tag", to: "german"))
        #expect(second.target.id == "fr")
        #expect(second.isReversed)
        #expect(await engine.log.calls == ["de>en", "fr>de", "de>fr"])
    }

    @Test func customPairsNeverReverse() throws {
        let service = TranslationService(engine: FakeEngine(), detector: detector)
        let route = try service.plan(request("hallo", to: "german"), fixedTarget: true)
        #expect(route.source.id == "de")
        #expect(route.target.id == "de")
        #expect(route.reversed == false)
    }

    @Test func anExplicitSourceSkipsDetection() throws {
        let service = TranslationService(engine: FakeEngine(), detector: detector)
        let route = try service.plan(request("xyz", to: "english", from: "french"))
        #expect(route.source.id == "fr")
        #expect(route.target.id == "en-US")
    }

    @Test func undetectableTextAsksForASource() {
        let service = TranslationService(engine: FakeEngine(), detector: detector)
        #expect(throws: TranslationFailure.unknownSourceLanguage) {
            try service.plan(request("xyz", to: "english"))
        }
    }

    @Test func missingModelsAndPairsAreReported() async {
        let download = TranslationService(engine: FakeEngine(availability: .needsDownload), detector: detector)
        await #expect(throws: TranslationFailure.needsDownload(source: "en-US", target: "de")) {
            try await download.translate(request("hello", to: "german"))
        }
        let unsupported = TranslationService(engine: FakeEngine(availability: .unsupported), detector: detector)
        await #expect(throws: TranslationFailure.unsupportedPair) {
            try await unsupported.translate(request("hello", to: "german"))
        }
        #expect(download.lastSource.id == "en-US")
    }
}

struct TranslatorCaseMappingTests {
    @Test func originalTextSurvivesCaseMapping() throws {
        let inline = try #require(TranslationParser.parse("İstanbul in english"))
        #expect(inline.text == "İstanbul")
        #expect(inline.target.id == "en-US")
        let command = try #require(TranslationParser.parse("translate İstanbul from turkish to english"))
        #expect(command.text == "İstanbul")
        #expect(command.source?.id == "tr")
        #expect(command.target.id == "en-US")
        let question = try #require(TranslationParser.parse("HOW DO YOU SAY İİİ IN GERMAN"))
        #expect(question.text == "İİİ")
        #expect(question.target.id == "de")
    }
}
