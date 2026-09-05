import AppKit
import Foundation
import Testing

@testable import OpenRay

struct PrivacyAndWindowTests {
    @Test(arguments: Array(ClipboardPolicy.ignoredTypes))
    func excludesConfidentialAndTransientClipboardTypes(_ type: String) {
        #expect(
            !ClipboardPolicy.shouldCapture(
                types: [type, "public.utf8-plain-text"], sourceBundleID: nil, excluded: [], secureInput: false))
    }

    @Test func excludesPasswordManagerChildrenAndSecureInput() {
        #expect(
            !ClipboardPolicy.shouldCapture(
                types: [], sourceBundleID: "com.example.passwords.helper", excluded: ["com.example.passwords"],
                secureInput: false))
        #expect(
            !ClipboardPolicy.shouldCapture(
                types: [], sourceBundleID: "com.apple.TextEdit", excluded: [], secureInput: true))
        #expect(
            ClipboardPolicy.shouldCapture(
                types: ["public.utf8-plain-text"], sourceBundleID: "com.apple.TextEdit",
                excluded: ["com.example.passwords"], secureInput: false))
    }

    @Test func snippetMatchesAtWordBoundaryOnlyAndSupportsBackspace() {
        let snippet = Snippet(name: "Greeting", keyword: ";hi", content: "Hello!")
        var matcher = SnippetMatcher()
        #expect(matcher.consume("x;hi", snippets: [snippet]) == nil)
        #expect(matcher.consume(" ;h", snippets: [snippet]) == nil)
        #expect(matcher.consume("z", snippets: [snippet]) == nil)
        #expect(matcher.consume("\u{7f}", snippets: [snippet]) == nil)
        #expect(matcher.consume("i", snippets: [snippet]) == snippet)
        #expect(matcher.buffer.isEmpty)
    }

    @Test func snippetBufferIsBoundedAndClearsOnNavigation() {
        var matcher = SnippetMatcher()
        #expect(matcher.consume(String(repeating: "x", count: 300), snippets: []) == nil)
        #expect(matcher.buffer.count == 64)
        #expect(matcher.consume("\n", snippets: []) == nil)
        #expect(matcher.buffer.isEmpty)
    }

    @Test func snippetExpandsDateWithoutChangingUnknownText() {
        let snippet = Snippet(name: "Date", keyword: ";date", content: "Today {date}, at {time}; {unknown}")
        let text = snippet.expanded(
            at: Date(timeIntervalSince1970: 0), locale: Locale(identifier: "en_US"), timeZone: .gmt)
        #expect(text.contains("Jan 1, 1970"))
        #expect(!text.contains("{time}"))
        #expect(text.contains("{unknown}"))
    }

    @Test func insertedUnicodeNeverSplitsSurrogatePairs() {
        let original = String(repeating: "x", count: 19) + "😀👩‍💻 Café 日本語\nSecond line"
        let chunks = SyntheticInput.unicodeChunks(original)
        #expect(chunks.allSatisfy { $0.count <= 20 })
        #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == original)
        #expect(SyntheticInput.unicodeChunks("").isEmpty)
    }

    @Test(arguments: ["x", "has space", "emoji😀", String(repeating: "x", count: 33)])
    func snippetRejectsUnsafeKeywords(_ keyword: String) {
        #expect(throws: LibraryValidationError.self) {
            try Snippet(name: "Test", keyword: keyword, content: "Text").validate(against: [])
        }
    }

    @Test func screenCoordinatesAreReversibleAcrossDisplays() {
        let display = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let flipped = ScreenCoordinates.flip(display, primaryHeight: 900)
        #expect(flipped == CGRect(x: -1920, y: 120, width: 1920, height: 1080))
        #expect(ScreenCoordinates.flip(flipped, primaryHeight: 900) == display)
    }

    @Test func layoutsRespectVisibleScreenAndSecondaryOrigins() {
        let screen = CGRect(x: -1600, y: 30, width: 1600, height: 870)
        let current = CGRect(x: 0, y: 0, width: 900, height: 600)
        #expect(
            WindowLayout.leftHalf.frame(in: screen, current: current)
                == CGRect(x: -1600, y: 30, width: 800, height: 870))
        #expect(
            WindowLayout.topRight.frame(in: screen, current: current)
                == CGRect(x: -800, y: 465, width: 800, height: 435))
        #expect(WindowLayout.maximize.frame(in: screen, current: current) == screen)
        #expect(
            WindowLayout.center.frame(in: screen, current: current) == CGRect(x: -1250, y: 165, width: 900, height: 600)
        )
    }

    @Test func centerFitsOversizedWindow() {
        let screen = CGRect(x: 100, y: 100, width: 800, height: 500)
        #expect(WindowLayout.center.frame(in: screen, current: CGRect(x: 0, y: 0, width: 2000, height: 2000)) == screen)
    }

    @Test func fixedSizeWindowsCanBeMovedWithoutAttemptingAResize() {
        let current = CGRect(x: 10, y: 20, width: 300, height: 400)
        let plan = WindowFramePlan(current: current, target: CGRect(x: 400, y: 300, width: 300, height: 400))
        #expect(plan.movesPosition)
        #expect(!plan.changesSize)
        #expect(plan.canApply(movable: true, resizable: false))
        let resize = WindowFramePlan(current: current, target: CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(!resize.canApply(movable: true, resizable: false))
    }

    @Test func unchangedWindowLayoutNeedsNoWritableAttributes() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 400)
        let plan = WindowFramePlan(current: frame, target: frame)
        #expect(plan.canApply(movable: false, resizable: false))
    }

    @MainActor @Test func clipboardWritesAreMarkedToAvoidRecapture() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenRayTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(store: LibraryStore(fileURL: nil), pasteboard: pasteboard)
        #expect(service.copy("A private test"))
        #expect(pasteboard.string(forType: .string) == "A private test")
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("com.openray.generated")) == true)
    }

    @MainActor @Test func monitoringCapturesNewTextAndHonorsPauseAndConfidentialMarkers() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenRayTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Before consent", forType: .string)
        let store = LibraryStore(fileURL: nil)
        store.update { $0.preferences.clipboardEnabled = true }
        let service = ClipboardService(
            store: store, pasteboard: pasteboard,
            captureContext: {
                ClipboardCaptureContext(sourceName: "Fixture", sourceBundleID: "test.fixture", secureInput: false)
            })
        service.configure()
        defer { service.stop() }
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("New copy", forType: .string)
        await service.poll()
        #expect(store.database.clipboard.first?.text == "New copy")
        pasteboard.clearContents()
        let concealed = NSPasteboardItem()
        concealed.setString("Secret", forType: .string)
        concealed.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([concealed])
        await service.poll()
        #expect(store.database.clipboard.count == 1)
        store.update { $0.preferences.clipboardEnabled = false }
        pasteboard.clearContents()
        pasteboard.setString("After pause", forType: .string)
        await service.poll()
        #expect(store.database.clipboard.count == 1)
    }
}
