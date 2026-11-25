import Foundation
import NaturalLanguage
import Observation
import Translation

/// A language the translator offers, named in English and in itself.
struct TranslationLanguage: Hashable, Sendable, Identifiable {
    /// A BCP 47 code: "de", "zh-Hans", "pt-BR".
    var id: String
    /// "German".
    var name: String
    /// Extra names people type: "deutsch", "mandarin", "brazilian portuguese".
    var aliases: [String]

    var language: Locale.Language { Locale.Language(identifier: id) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum TranslationLanguages {
    /// Languages Apple's on-device Translation framework covers. Availability on this
    /// Mac is checked at run time; a missing model downloads on first use.
    static let all: [TranslationLanguage] = [
        .init(id: "ar", name: "Arabic", aliases: ["العربية"]),
        .init(id: "zh-Hans", name: "Chinese", aliases: ["simplified chinese", "chinese simplified", "mandarin", "中文", "简体中文"]),
        .init(id: "zh-Hant", name: "Traditional Chinese", aliases: ["chinese traditional", "繁體中文", "cantonese"]),
        .init(id: "nl", name: "Dutch", aliases: ["nederlands", "flemish"]),
        english,
        .init(id: "en-GB", name: "British English", aliases: ["uk english"]),
        .init(id: "fr", name: "French", aliases: ["français", "francais"]),
        .init(id: "de", name: "German", aliases: ["deutsch"]),
        .init(id: "hi", name: "Hindi", aliases: ["हिन्दी"]),
        .init(id: "id", name: "Indonesian", aliases: ["bahasa indonesia"]),
        .init(id: "it", name: "Italian", aliases: ["italiano"]),
        .init(id: "ja", name: "Japanese", aliases: ["日本語"]),
        .init(id: "ko", name: "Korean", aliases: ["한국어"]),
        .init(id: "pl", name: "Polish", aliases: ["polski"]),
        .init(id: "pt-BR", name: "Portuguese", aliases: ["brazilian portuguese", "português", "portugues"]),
        .init(id: "ru", name: "Russian", aliases: ["русский"]),
        .init(id: "es", name: "Spanish", aliases: ["español", "espanol", "castellano"]),
        .init(id: "th", name: "Thai", aliases: ["ไทย"]),
        .init(id: "tr", name: "Turkish", aliases: ["türkçe", "turkce"]),
        .init(id: "uk", name: "Ukrainian", aliases: ["українська"]),
        .init(id: "vi", name: "Vietnamese", aliases: ["tiếng việt", "tieng viet"]),
    ]

    static let english = TranslationLanguage(id: "en-US", name: "English", aliases: ["american english", "us english"])

    /// The language a typed name means. Names need three or more letters, so codes
    /// such as "de" never trigger a translation by accident. A unique prefix of five
    /// or more letters also counts ("portug").
    static func named(_ text: String) -> TranslationLanguage? {
        let key = fold(text)
        guard key.count >= 3 else { return nil }
        if let exact = byName[key] { return exact }
        guard key.count >= 5 else { return nil }
        let prefixed = Set(byName.filter { $0.key.hasPrefix(key) }.map(\.value))
        return prefixed.count == 1 ? prefixed.first : nil
    }

    /// The closest offered language to a detected one: "pt" → Portuguese, "en" → English.
    static func matching(_ language: Locale.Language) -> TranslationLanguage? {
        let code = language.languageCode?.identifier
        if code == "zh" {
            return all.first { $0.id == (language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans") }
        }
        if code == "en", language.region?.identifier == "GB" { return all.first { $0.id == "en-GB" } }
        return all.first { $0.language.languageCode?.identifier == code }
    }

    private static let byName: [String: TranslationLanguage] = {
        var table: [String: TranslationLanguage] = [:]
        for language in all {
            for name in [language.name] + language.aliases where table[fold(name)] == nil {
                table[fold(name)] = language
            }
        }
        return table
    }()

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Text to translate, and the languages a phrasing asked for.
struct TranslationRequest: Equatable, Sendable {
    var text: String
    /// Nil to detect the source.
    var source: TranslationLanguage?
    var target: TranslationLanguage
}

/// Reads inline phrasings: "hello in german", "good night into french",
/// "translate bonjour to english", "translate hallo from german to english",
/// "how do you say thank you in japanese". Pure, so it's tested directly.
enum TranslationParser {
    static let maximumLength = 500

    static func parse(_ input: String) -> TranslationRequest? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength, trimmed.count >= 4 else { return nil }
        if let command = commandPhrase(trimmed) { return command }
        for prefix in ["how do you say ", "how to say ", "how would you say ", "say "] where trimmed.lowercased().hasPrefix(prefix) {
            return inline(String(trimmed.dropFirst(prefix.count)), connectors: [" in ", " into "])
        }
        return inline(trimmed, connectors: [" in ", " into "])
    }

    /// "translate X to|into|in L" and "translate X from L1 to L2".
    private static func commandPhrase(_ text: String) -> TranslationRequest? {
        let lower = text.lowercased()
        guard lower.hasPrefix("translate ") else { return nil }
        let body = String(text.dropFirst("translate ".count))
        if let request = inline(body, connectors: [" to ", " into ", " in "]) {
            if let (text, source) = sourceSuffix(request.text) {
                return TranslationRequest(text: text, source: source, target: request.target)
            }
            return request
        }
        return nil
    }

    /// "<text> in|into <language>", splitting at the last connector so "in" inside the
    /// text stays. The text may be quoted.
    private static func inline(_ text: String, connectors: [String]) -> TranslationRequest? {
        let lower = text.lowercased()
        var best: (range: Range<String.Index>, language: TranslationLanguage)?
        for connector in connectors {
            guard let range = lower.range(of: connector, options: .backwards) else { continue }
            let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
            guard let language = TranslationLanguages.named(name) else { continue }
            if best == nil || range.lowerBound > best!.range.lowerBound { best = (range, language) }
        }
        guard let best else { return nil }
        let source = unquoted(String(text[..<best.range.lowerBound]))
        guard !source.isEmpty, source.contains(where: \.isLetter) else { return nil }
        return TranslationRequest(text: source, source: nil, target: best.language)
    }

    /// "hallo from german" → ("hallo", German).
    private static func sourceSuffix(_ text: String) -> (String, TranslationLanguage)? {
        guard let range = text.lowercased().range(of: " from ", options: .backwards) else { return nil }
        let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let language = TranslationLanguages.named(name) else { return nil }
        let remaining = unquoted(String(text[..<range.lowerBound]))
        return remaining.isEmpty ? nil : (remaining, language)
    }

    private static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("«", "»")]
        for (open, close) in quotes where trimmed.count >= 2 && trimmed.first == open && trimmed.last == close {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}

// MARK: - Seams

/// Finds the language of a text. The real one uses NaturalLanguage, on device.
protocol LanguageDetecting: Sendable {
    func dominantLanguage(of text: String) -> Locale.Language?
}

struct NaturalLanguageDetector: LanguageDetecting {
    func dominantLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}

enum TranslationAvailability: Equatable, Sendable {
    /// The model is on this Mac.
    case installed
    /// Supported, but the model needs a one-time download, which needs a visible
    /// SwiftUI `translationTask` to ask for consent.
    case needsDownload
    case unsupported
}

enum TranslationFailure: Error, Equatable, Sendable {
    case needsDownload(source: String, target: String)
    case unsupportedPair
    case unknownSourceLanguage
    case failed(String)

    var message: String {
        switch self {
        case .needsDownload: "Download the language to translate on this Mac."
        case .unsupportedPair: "This language pair isn't available on this Mac."
        case .unknownSourceLanguage: "OpenRay couldn't tell which language this is. Choose the source language."
        case .failed(let reason): reason
        }
    }
}

/// Translates on device. Tests use a fake.
protocol TranslationEngine: Sendable {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
}

/// Apple's Translation framework with installed models only, so it never downloads
/// or prompts by itself.
struct AppleTranslationEngine: TranslationEngine {
    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: .installed
        case .supported: .needsDownload
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        let session = TranslationSession(installedSource: source, target: target)
        do {
            return try await session.translate(text).targetText
        } catch TranslationError.notInstalled {
            throw TranslationFailure.needsDownload(source: source.minimalIdentifier, target: target.minimalIdentifier)
        } catch TranslationError.unsupportedLanguagePairing {
            throw TranslationFailure.unsupportedPair
        } catch TranslationError.unableToIdentifyLanguage {
            throw TranslationFailure.unknownSourceLanguage
        }
    }
}

// MARK: - Service

struct TranslationOutcome: Equatable, Sendable {
    var sourceText: String
    var translatedText: String
    var source: TranslationLanguage
    var target: TranslationLanguage
    /// The text was already in the target, so it went the other way, to the last
    /// source language. Shown as "(Auto)".
    var isReversed: Bool
}

/// Decides directions and runs translations: detects the source, reverses when the
/// text is already in the target, and remembers the last source for that reversal.
@MainActor
@Observable
final class TranslationService {
    /// Where same-language text goes. English until another source is used.
    private(set) var lastSource: TranslationLanguage = TranslationLanguages.english

    @ObservationIgnored private let engine: any TranslationEngine
    @ObservationIgnored private let detector: any LanguageDetecting

    init(engine: any TranslationEngine = AppleTranslationEngine(), detector: any LanguageDetecting = NaturalLanguageDetector()) {
        self.engine = engine
        self.detector = detector
    }

    /// The source and target to use. `fixedTarget` is for custom pair commands, which
    /// always translate into their target and never reverse.
    func plan(_ request: TranslationRequest, fixedTarget: Bool = false) throws -> (
        source: TranslationLanguage, target: TranslationLanguage, reversed: Bool
    ) {
        let source: TranslationLanguage
        if let explicit = request.source {
            source = explicit
        } else if let detected = detector.dominantLanguage(of: request.text).flatMap(TranslationLanguages.matching) {
            source = detected
        } else {
            throw TranslationFailure.unknownSourceLanguage
        }
        guard !fixedTarget, Self.sameLanguage(source, request.target) else {
            return (source, request.target, false)
        }
        let fallback = Self.sameLanguage(lastSource, source) ? TranslationLanguages.english : lastSource
        if Self.sameLanguage(fallback, source) {
            return (source, request.target, false)
        }
        return (source, fallback, true)
    }

    func translate(_ request: TranslationRequest, fixedTarget: Bool = false) async throws -> TranslationOutcome {
        let route = try plan(request, fixedTarget: fixedTarget)
        switch await engine.availability(from: route.source.language, to: route.target.language) {
        case .installed: break
        case .needsDownload:
            throw TranslationFailure.needsDownload(source: route.source.id, target: route.target.id)
        case .unsupported: throw TranslationFailure.unsupportedPair
        }
        let text = try await engine.translate(request.text, from: route.source.language, to: route.target.language)
        if !route.reversed { lastSource = route.source }
        return TranslationOutcome(
            sourceText: request.text, translatedText: text, source: route.source, target: route.target,
            isReversed: route.reversed)
    }

    private static func sameLanguage(_ a: TranslationLanguage, _ b: TranslationLanguage) -> Bool {
        a.language.languageCode == b.language.languageCode
            && (a.language.languageCode?.identifier != "zh" || a.id == b.id)
    }
}
