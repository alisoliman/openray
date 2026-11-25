import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

struct TextRecognitionTests {
    @Test func recognizesRenderedText() async throws {
        let png = try OCRFixtures.png(text: "OPENRAY 2026")
        let result = try await VisionTextRecognizer().recognizeText(in: png)
        let text = result.text.uppercased().replacingOccurrences(of: " ", with: "")
        #expect(text.contains("OPENRAY"))
        #expect(text.contains("2026"))
        #expect(result.lines.allSatisfy { $0.confidence >= 0.3 })
        let box = try #require(result.lines.first?.boundingBox)
        #expect(box.minX >= 0 && box.maxX <= 1 && box.minY >= 0 && box.maxY <= 1)
        #expect(result.storableText?.isEmpty == false)
    }

    @Test func recognizesTextInAFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayOCR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "shot.png")
        try OCRFixtures.png(text: "INVOICE 42").write(to: url)
        let result = try await VisionTextRecognizer().recognizeText(inImageAt: url, options: .init(level: .accurate, languages: ["en-US"]))
        #expect(result.text.uppercased().contains("INVOICE"))
    }

    @Test func blankImagesHaveNoText() async throws {
        let blank = try OCRFixtures.png(text: "")
        let result = try await VisionTextRecognizer().recognizeText(in: blank, options: .init(level: .fast))
        #expect(result.isEmpty)
        #expect(result.storableText == nil)
    }

    @Test func readsQRCodes() async throws {
        let message = "https://example.com/openray?q=1"
        let payloads = try await VisionTextRecognizer().barcodePayloads(in: try OCRFixtures.qrCode(message))
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
