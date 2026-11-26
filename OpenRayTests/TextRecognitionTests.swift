import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision

@testable import OpenRay

private enum OCRFixtures {
    /// Black text on white, drawn with Core Text into a bitmap made by the test.
    static func png(text: String, width: Int = 1_000, height: Int = 220, fontSize: CGFloat = 80) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, context)
        return try encode(try #require(context.makeImage()))
    }

    /// Text stored rotated 90° counterclockwise with EXIF orientation 6, which
    /// tells viewers to turn it clockwise, as cameras write portrait photos.
    static func rotatedTIFF(text: String) throws -> Data {
        let uprightPNG = try png(text: text)
        let source = try #require(CGImageSourceCreateWithData(uprightPNG as CFData, nil))
        let upright = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = upright.width
        let height = upright.height
        let context = try #require(
            CGContext(
                data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(upright, in: CGRect(x: 0, y: 0, width: width, height: height))
        let stored = try #require(context.makeImage())
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, stored, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    static func qrCode(_ message: String) throws -> Data {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        let output = try #require(filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)))
        // A quiet zone around the code helps detection.
        let padded = output.transformed(by: CGAffineTransform(translationX: 48, y: 48))
            .composited(over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -48, dy: -48).offsetBy(dx: 48, dy: 48)))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let image = try #require(context.createCGImage(padded, from: padded.extent))
        return try encode(image)
    }

    static func encode(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }
}

/// Shows the protocol is enough for callers: no Vision needed.
private struct FakeRecognizer: TextRecognizing {
    var lines: [String]

    func recognizeText(in imageData: Data, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        TextRecognitionResult(lines: lines.map { RecognizedTextLine(text: $0, confidence: 1, boundingBox: .zero) })
    }

    func recognizeText(inImageAt url: URL, options: TextRecognitionOptions) async throws -> TextRecognitionResult {
        try await recognizeText(in: Data(), options: options)
    }

    func barcodePayloads(in imageData: Data) async throws -> [String] { [] }
}

/// Vision's text recognizer compiles on-device models that some machines can't run: GitHub's
/// macOS virtual machines fail with `e5rt_e5_compiler_compile` / `.unknownError`. The tests that
/// recognize real text run only where a one-time probe succeeds; OpenRay's own OCR logic is
/// covered with fakes everywhere.
private enum VisionOCRProbe {
    static let isAvailable: Bool = {
        guard let png = try? OCRFixtures.png(text: "OPENRAY 42"),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return !(request.results ?? []).isEmpty
        } catch {
            return false
        }
    }()

    static let unavailableReason: Comment = "Vision text recognition can't run on this machine (for example a CI virtual machine)"
}

/// Vision occasionally fails with a transient runtime error (Neural Engine or model loading)
/// when the machine is under heavy load. Those calls are retried; a wrong recognition result
/// still fails the test, and `TextRecognitionError` is never retried.
func withVisionRetry<T>(attempts: Int = 3, _ body: () async throws -> T) async throws -> T {
    var lastError: Error?
    for attempt in 1...attempts {
        do { return try await body() } catch let error as TextRecognitionError { throw error } catch {
            lastError = error
            if attempt < attempts { try await Task.sleep(for: .milliseconds(300 * attempt)) }
        }
    }
    throw lastError!
}

/// Serialized: running several Vision requests at once under a loaded test host is what
/// triggers the transient runtime errors.
@Suite(.serialized)
struct TextRecognitionTests {
    @Test(.enabled(if: VisionOCRProbe.isAvailable, VisionOCRProbe.unavailableReason))
    func recognizesRenderedText() async throws {
        let png = try OCRFixtures.png(text: "OPENRAY 2026")
        let result = try await withVisionRetry { try await VisionTextRecognizer().recognizeText(in: png) }
        let text = result.text.uppercased().replacingOccurrences(of: " ", with: "")
        #expect(text.contains("OPENRAY"))
        #expect(text.contains("2026"))
        #expect(result.lines.allSatisfy { $0.confidence >= 0.3 })
        let box = try #require(result.lines.first?.boundingBox)
        #expect(box.minX >= 0 && box.maxX <= 1 && box.minY >= 0 && box.maxY <= 1)
        #expect(result.storableText?.isEmpty == false)
    }

    @Test(.enabled(if: VisionOCRProbe.isAvailable, VisionOCRProbe.unavailableReason))
    func recognizesTextInAFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayOCR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "shot.png")
        try OCRFixtures.png(text: "INVOICE 42").write(to: url)
        let result = try await withVisionRetry {
            try await VisionTextRecognizer().recognizeText(inImageAt: url, options: .init(level: .accurate, languages: ["en-US"]))
        }
        #expect(result.text.uppercased().contains("INVOICE"))
    }

    @Test(.enabled(if: VisionOCRProbe.isAvailable, VisionOCRProbe.unavailableReason))
    func orientationMetadataIsApplied() async throws {
        let tiff = try OCRFixtures.rotatedTIFF(text: "OPENRAY 2026")
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
        let result = try await withVisionRetry { try await VisionTextRecognizer().recognizeText(in: tiff) }
        #expect(result.text.uppercased().replacingOccurrences(of: " ", with: "").contains("OPENRAY"))
        // Boxes are in the upright image: a wide line of text stays wide.
        let box = try #require(result.lines.first?.boundingBox)
        #expect(box.width > box.height)
    }

    @Test func blankImagesHaveNoText() async throws {
        let blank = try OCRFixtures.png(text: "")
        let result = try await withVisionRetry { try await VisionTextRecognizer().recognizeText(in: blank, options: .init(level: .fast)) }
        #expect(result.isEmpty)
        #expect(result.storableText == nil)
    }

    @Test func readsQRCodes() async throws {
        let message = "https://example.com/openray?q=1"
        let qr = try OCRFixtures.qrCode(message)
        let payloads = try await withVisionRetry { try await VisionTextRecognizer().barcodePayloads(in: qr) }
        #expect(payloads == [message])
    }

    @Test func refusesUnreadableData() async {
        await #expect(throws: TextRecognitionError.unreadableImage) {
            try await VisionTextRecognizer().recognizeText(in: Data())
        }
        await #expect(throws: TextRecognitionError.unreadableImage) {
            try await VisionTextRecognizer().recognizeText(in: Data("not an image".utf8))
        }
        await #expect(throws: TextRecognitionError.unreadableImage) {
            try await VisionTextRecognizer().recognizeText(
                inImageAt: URL(fileURLWithPath: "/nonexistent/\(UUID()).png"), options: .init())
        }
        #expect(TextRecognitionError.imageTooLarge.errorDescription?.isEmpty == false)
    }

    @Test func storableTextIsJoinedAndBounded() async throws {
        let recognizer: any TextRecognizing = FakeRecognizer(lines: ["First line", "Second line"])
        let result = try await recognizer.recognizeText(in: Data())
        #expect(result.text == "First line\nSecond line")
        #expect(result.storableText == "First line\nSecond line")

        let long = TextRecognitionResult(lines: [
            .init(text: String(repeating: "é", count: ClipboardLimits.recognizedTextBytes), confidence: 1, boundingBox: .zero)
        ])
        let stored = try #require(long.storableText)
        #expect(stored.utf8.count <= ClipboardLimits.recognizedTextBytes)
        #expect(stored.count == ClipboardLimits.recognizedTextBytes / 2)
    }
}
