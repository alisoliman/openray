import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device text and QR-code recognition for clipboard images and screenshots.
/// UI-free and behind a protocol, so callers and tests can swap in a fake.

struct RecognizedTextLine: Equatable, Sendable {
    var text: String
    /// Vision's confidence, from 0 to 1.
    var confidence: Float
    /// The line's bounds in normalized coordinates of the upright image, after any
    /// orientation metadata is applied (0 to 1, origin at the bottom left).
    var boundingBox: CGRect
}

struct TextRecognitionResult: Equatable, Sendable {
    /// Lines in Vision's reading order.
    var lines: [RecognizedTextLine]

    /// All lines joined by line breaks, for search and "Copy Text".
    var text: String { lines.map(\.text).joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty }

    /// The text cut to what a clipboard entry stores, on a character boundary.
    var storableText: String? {
        let joined = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        var result = ""
        var bytes = 0
        for character in joined {
            let size = String(character).utf8.count
            guard bytes + size <= ClipboardLimits.recognizedTextBytes else { break }
            bytes += size
            result.append(character)
        }
        return result
    }
}

struct TextRecognitionOptions: Equatable, Sendable {
    enum Level: Equatable, Sendable { case accurate, fast }

    var level: Level = .accurate
    /// BCP 47 language identifiers to prefer. Empty means automatic detection.
    var languages: [String] = []
    var usesLanguageCorrection = true
    /// Lines below this confidence are dropped.
    var minimumConfidence: Float = 0.3

    init(
        level: Level = .accurate, languages: [String] = [], usesLanguageCorrection: Bool = true,
        minimumConfidence: Float = 0.3
    ) {
        self.level = level
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumConfidence = minimumConfidence
    }
}

enum TextRecognitionError: LocalizedError, Equatable {
    case unreadableImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "This image couldn't be read for text recognition."
        case .imageTooLarge: "This image is too large for text recognition."
        }
    }
}

protocol TextRecognizing: Sendable {
    /// Text in encoded image data such as PNG, JPEG or TIFF.
    func recognizeText(in imageData: Data, options: TextRecognitionOptions) async throws -> TextRecognitionResult
    /// Text in an image file, e.g. a screenshot.
    func recognizeText(inImageAt url: URL, options: TextRecognitionOptions) async throws -> TextRecognitionResult
    /// The text payloads of QR codes and other barcodes in the image.
    func barcodePayloads(in imageData: Data) async throws -> [String]
}

/// Recognition with the Vision framework. Everything runs on this Mac.
struct VisionTextRecognizer: TextRecognizing {
    /// Images above this are refused rather than decoded, matching the clipboard limits.
    static let maximumPixels = ClipboardLimits.imagePixels
    static let maximumBytes = ClipboardLimits.sourceImageBytes

    func recognizeText(in imageData: Data, options: TextRecognitionOptions = .init()) async throws
        -> TextRecognitionResult
    {
        let (image, orientation) = try Self.decode(imageData)
        return try await recognize(image, orientation: orientation, options: options)
    }

    func recognizeText(inImageAt url: URL, options: TextRecognitionOptions = .init()) async throws
        -> TextRecognitionResult
    {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { throw TextRecognitionError.unreadableImage }
        guard (values?.fileSize ?? 0) <= Self.maximumBytes else { throw TextRecognitionError.imageTooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw TextRecognitionError.unreadableImage }
        let (image, orientation) = try Self.image(from: source)
        return try await recognize(image, orientation: orientation, options: options)
    }

    func barcodePayloads(in imageData: Data) async throws -> [String] {
        let (image, orientation) = try Self.decode(imageData)
        let observations = try await DetectBarcodesRequest().perform(on: image, orientation: orientation)
        var seen = Set<String>()
        return observations.compactMap(\.payloadString).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func recognize(
        _ image: CGImage, orientation: CGImagePropertyOrientation, options: TextRecognitionOptions
    ) async throws -> TextRecognitionResult {
        try Task.checkCancellation()
        var request = RecognizeTextRequest()
        request.recognitionLevel = options.level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if options.languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = options.languages.map { Locale.Language(identifier: $0) }
        }
        let observations = try await request.perform(on: image, orientation: orientation)
        try Task.checkCancellation()
        let lines = observations.compactMap { observation -> RecognizedTextLine? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= options.minimumConfidence
            else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedTextLine(
                text: text, confidence: candidate.confidence, boundingBox: observation.boundingBox.cgRect)
        }
        return TextRecognitionResult(lines: lines)
    }

    private static func decode(_ data: Data) throws -> (CGImage, CGImagePropertyOrientation) {
        guard !data.isEmpty else { throw TextRecognitionError.unreadableImage }
        guard data.count <= maximumBytes else { throw TextRecognitionError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw TextRecognitionError.unreadableImage }
        return try image(from: source)
    }

    /// Checks the pixel count before decoding, so a huge image is refused cheaply.
    /// ImageIO returns the stored pixels, so the EXIF orientation travels with them
    /// to Vision, which reads the image upright.
    private static func image(from source: CGImageSource) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { throw TextRecognitionError.unreadableImage }
        guard width <= maximumPixels / height else { throw TextRecognitionError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TextRecognitionError.unreadableImage
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        return (image, orientation)
    }
}

extension TextRecognizing {
    func recognizeText(in imageData: Data) async throws -> TextRecognitionResult {
        try await recognizeText(in: imageData, options: TextRecognitionOptions())
    }
}
