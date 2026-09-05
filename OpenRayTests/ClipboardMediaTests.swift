import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OpenRay

enum ClipboardFixtures {
    @MainActor static func writeImage(_ data: Data, to board: NSPasteboard, type: NSPasteboard.PasteboardType = .png) {
        let previousChange = board.changeCount
        board.clearContents()
        #expect(board.setData(data, forType: type))
        #expect(board.changeCount != previousChange)
    }
    static func image(width: Int = 48, height: Int = 32, red: CGFloat = 0.2, format: UTType = .png) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0.35, blue: 0.85, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, format.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    static func dimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }
}

actor GatedImagePreparer: ClipboardImagePreparing {
    let result: PreparedClipboardImage
    private var didStart = false
    private var release: AsyncStream<Void>.Continuation?

    init(result: PreparedClipboardImage) { self.result = result }

    func prepare(_ data: Data) async throws -> PreparedClipboardImage {
        try Task.checkCancellation()
        let gate = AsyncStream<Void>.makeStream()
        release = gate.continuation
        didStart = true
        for await _ in gate.stream {}
        try Task.checkCancellation()
        return result
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !didStart && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard didStart else { throw LibraryValidationError("The test capture never reached image processing.") }
    }

    func finish() {
        release?.finish()
        release = nil
    }
}

@MainActor
struct ClipboardMediaTests {
    private func makeStore() -> LibraryStore {
        let store = LibraryStore(fileURL: nil)
        store.update { $0.preferences.clipboardEnabled = true }
        return store
    }

    private func makeService(
        store: LibraryStore, pasteboard: NSPasteboard,
        processor: any ClipboardImagePreparing = ClipboardImageProcessor.shared,
        context: ClipboardCaptureContext = .init(
            sourceName: "Fixture", sourceBundleID: "test.fixture", secureInput: false)
    ) -> ClipboardService {
        pasteboard.clearContents()
        return ClipboardService(
            store: store, pasteboard: pasteboard, imageProcessor: processor, captureContext: { context })
    }

    @Test func capturesPNGAndCopiesAnImageRatherThanText() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board)
        ClipboardFixtures.writeImage(try ClipboardFixtures.image(), to: board)
        await service.poll()
        let entry = try #require(store.database.clipboard.first)
        let image = try #require(entry.image)
        #expect(image.pixelWidth == 48 && image.pixelHeight == 32)
        #expect(entry.plainText == nil)
        #expect(entry.kindTitle == "Image")
        #expect(service.copy(entry))
        let copied = try #require(board.data(forType: .png))
        let dimensions = try ClipboardFixtures.dimensions(copied)
        #expect(dimensions.width == 48 && dimensions.height == 32)
        #expect(board.string(forType: .string) == nil)
        #expect(board.types?.contains(.init("com.openray.generated")) == true)
        await service.poll()
        #expect(store.database.clipboard.count == 1)
    }

    @Test func acceptsTIFFAndStoresCanonicalPNG() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board)
        ClipboardFixtures.writeImage(try ClipboardFixtures.image(format: .tiff), to: board, type: .tiff)
        await service.poll()
        let image = try #require(store.database.clipboard.first?.image)
        let data = try #require(store.imageData(for: image))
        #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    }

    @Test func copiedFilesRemainMultipleFileReferencesAndOriginalsAreUntouched() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OpenRayMediaTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = [folder.appending(path: "Résumé one.txt"), folder.appending(path: "two.txt")]
        for url in urls { try Data("original".utf8).write(to: url) }
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board)
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        board.clearContents()
        #expect(board.writeObjects(items))
        await service.poll()
        let entry = try #require(store.database.clipboard.first)
        #expect(entry.content == .files(urls))
        #expect(entry.searchableText.contains("Résumé"))
        #expect(service.copy(entry))
        let copiedURLs = board.pasteboardItems?.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }
        #expect(copiedURLs == urls)
        #expect(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.count == 2)
        #expect(service.clearHistory())
        for url in urls { #expect(try String(contentsOf: url, encoding: .utf8) == "original") }
    }

    @Test func mediaCaptureHonorsPerTypeOptIn() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        store.update {
            $0.preferences.clipboardImagesEnabled = false
            $0.preferences.clipboardFilesEnabled = false
        }
        let service = makeService(store: store, pasteboard: board)
        ClipboardFixtures.writeImage(try ClipboardFixtures.image(), to: board)
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
        board.clearContents()
        board.setString("file:///tmp/example.txt", forType: .fileURL)
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
        board.clearContents()
        board.setString("Still captures text", forType: .string)
        await service.poll()
        #expect(store.database.clipboard.first?.text == "Still captures text")
    }

    @Test func confidentialImagesAreSkippedBeforeDecoding() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board)
        let item = NSPasteboardItem()
        item.setData(Data("invalid image".utf8), forType: .png)
        item.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents()
        #expect(board.writeObjects([item]))
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
        #expect(service.contentMessage == nil)
    }

    @Test(arguments: [
        ClipboardCaptureContext(
            sourceName: "Password Manager", sourceBundleID: "com.apple.Passwords", secureInput: false),
        ClipboardCaptureContext(sourceName: "Secure Field", sourceBundleID: "test.fixture", secureInput: true),
    ])
    func mediaCaptureRespectsExcludedAppsAndSecureInput(_ context: ClipboardCaptureContext) async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board, context: context)
        ClipboardFixtures.writeImage(try ClipboardFixtures.image(), to: board)
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
    }

    @Test func pausingWhileAnImageIsProcessedDoesNotSaveItLater() async throws {
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        let processor = GatedImagePreparer(result: prepared)
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board, processor: processor)
        service.configure()
        defer { service.stop() }
        ClipboardFixtures.writeImage(prepared.png, to: board)
        let capture = Task { await service.poll() }
        defer {
            capture.cancel()
            Task { await processor.finish() }
        }
        try await processor.waitUntilStarted()
        #expect(service.isProcessing)
        store.update { $0.preferences.clipboardEnabled = false }
        service.configure()
        await processor.finish()
        await capture.value
        #expect(store.database.clipboard.isEmpty)
        #expect(store.imageData(for: prepared.image) == nil)
        #expect(!service.isProcessing)
    }

    @Test func clearingWhileAnImageIsProcessedDoesNotResurrectHistory() async throws {
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        let processor = GatedImagePreparer(result: prepared)
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board, processor: processor)
        ClipboardFixtures.writeImage(prepared.png, to: board)
        let capture = Task { await service.poll() }
        defer {
            capture.cancel()
            Task { await processor.finish() }
        }
        try await processor.waitUntilStarted()
        #expect(service.clearHistory())
        await processor.finish()
        await capture.value
        #expect(store.database.clipboard.isEmpty)
        #expect(store.imageData(for: prepared.image) == nil)
    }

    @Test func textCopiedDuringImageProcessingIsCapturedOnNextPoll() async throws {
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        let processor = GatedImagePreparer(result: prepared)
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, pasteboard: board, processor: processor)
        ClipboardFixtures.writeImage(prepared.png, to: board)
        let capture = Task { await service.poll() }
        defer {
            capture.cancel()
            Task { await processor.finish() }
        }
        try await processor.waitUntilStarted()
        board.clearContents()
        board.setString("Copied during processing", forType: .string)
        await service.poll()
        await processor.finish()
        await capture.value
        await service.poll()
        #expect(store.database.clipboard.count == 2)
        #expect(store.database.clipboard.first?.text == "Copied during processing")
    }

    @Test func differentImagesDoNotCollapseIntoOneEmptyTextEntry() throws {
        let store = makeStore()
        let blue = try ClipboardImageCodec.prepare(ClipboardFixtures.image())
        let orange = try ClipboardImageCodec.prepare(ClipboardFixtures.image(red: 0.9))
        #expect(store.captureImage(blue, sourceName: "First app"))
        let firstID = try #require(store.database.clipboard.first?.id)
        #expect(store.captureImage(orange, sourceName: "Second app"))
        #expect(store.database.clipboard.count == 2)
        #expect(store.captureImage(blue, sourceName: "Third app"))
        #expect(store.database.clipboard.count == 2)
        #expect(store.database.clipboard.first?.id == firstID)
        #expect(store.database.clipboard.first?.sourceName == "Third app")
    }

    @Test func typeFiltersDoNotHideUnrelatedKindsOrTreatImagesAsText() throws {
        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image()).image
        let entries = [
            ClipboardEntry(text: "A text entry", sourceName: "Fixture"),
            ClipboardEntry(content: .image(image), sourceName: "Fixture"),
            ClipboardEntry(content: .files([URL(fileURLWithPath: "/tmp/file.txt")]), sourceName: "Fixture"),
        ]
        #expect(entries.filter(ClipboardFilter.all.includes).count == 3)
        #expect(entries.filter(ClipboardFilter.text.includes).map(\.kindTitle) == ["Text"])
        #expect(entries.filter(ClipboardFilter.images.includes).map(\.kindTitle) == ["Image"])
        #expect(entries.filter(ClipboardFilter.files.includes).map(\.kindTitle) == ["File"])
        #expect(entries[1].plainText == nil && entries[2].plainText == nil)
    }

    @Test func privateVerificationModeCannotFallBackToTheGeneralPasteboard() {
        let invalid = RuntimeMode.launchPasteboard(arguments: ["OpenRay", "--verification-pasteboard", "general"])
        defer { invalid.releaseGlobally() }
        #expect(invalid.name != NSPasteboard.Name.general)
        #expect(
            RuntimeMode.verificationPasteboardName(arguments: [
                "OpenRay", "--verification-pasteboard", "OpenRayVerification.Test",
            ]) == nil)
        let arguments = [
            "OpenRay", "--in-memory-library", "--verification-pasteboard", "OpenRayVerification.\(UUID())",
        ]
        let valid = RuntimeMode.launchPasteboard(arguments: arguments)
        defer { valid.releaseGlobally() }
        #expect(valid.name.rawValue == arguments.last)
        let store = makeStore()
        let model = LauncherModel(store: store, ai: AIChatModel(engine: TestAIEngine()), pasteboard: valid)
        model.paste("Verification text")
        #expect(valid.string(forType: .string) == "Verification text")
        #expect(model.message?.contains("Cross-app paste is disabled") == true)
    }

    @Test func imageThumbnailIsDownsampledAndCorruptDataIsRejected() async throws {
        let prepared = try ClipboardImageCodec.prepare(ClipboardFixtures.image(width: 320, height: 240))
        let thumbnail = try #require(
            await ClipboardImageProcessor.shared.thumbnail(.memory(prepared.image, prepared.png), maxPixelSize: 32))
        let dimensions = try ClipboardFixtures.dimensions(thumbnail)
        #expect(dimensions.width <= 32 && dimensions.height <= 32)
        #expect(prepared.image.pixelWidth == 320)
        #expect(throws: LibraryValidationError.self) { try ClipboardImageCodec.prepare(Data("not an image".utf8)) }
        #expect(!ClipboardImage(id: "../outside", pixelWidth: 1, pixelHeight: 1, byteCount: 1).isValid)
        #expect(
            !ClipboardImage(id: String(repeating: "a", count: 64), pixelWidth: Int.max, pixelHeight: 2, byteCount: 1)
                .isValid)
    }
}
