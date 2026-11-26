import AppKit
import Foundation
import Testing

@testable import OpenRay

private let sampleRTF = Data(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0\b Bold\b0  text}"#.utf8)
private let sampleHTML = Data("<b>Bold</b> text".utf8)

@MainActor
struct ClipboardRichTextTests {
    private func makeStore() -> LibraryStore {
        let store = LibraryStore(fileURL: nil)
        store.update { $0.preferences.clipboardEnabled = true }
        return store
    }

    private func makeService(store: LibraryStore, board: NSPasteboard) -> ClipboardService {
        board.clearContents()
        return ClipboardService(
            store: store, pasteboard: board,
            captureContext: { .init(sourceName: "Fixture", sourceBundleID: "test.fixture", secureInput: false) })
    }

    private func write(_ representations: [(NSPasteboard.PasteboardType, Data)], to board: NSPasteboard) {
        board.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in representations { item.setData(data, forType: type) }
        #expect(board.writeObjects([item]))
    }

    // MARK: Capture

    @Test func capturesRTFAndHTMLNextToPlainText() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, board: board)
        write([(.rtf, sampleRTF), (.html, sampleHTML), (.string, Data("Bold text".utf8))], to: board)
        await service.poll()
        let entry = try #require(store.database.clipboard.first)
        #expect(entry.plainText == "Bold text")
        #expect(entry.richText == ClipboardRichText(rtf: sampleRTF, html: sampleHTML))
        #expect(entry.byteCount == "Bold text".utf8.count + sampleRTF.count + sampleHTML.count)
        #expect(entry.kindTitle == "Text")
    }

    @Test func oversizedFormattingIsDroppedButTheTextIsKept() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, board: board)
        let huge = Data(repeating: 0x41, count: ClipboardLimits.richTextBytes + 1)
        write([(.rtf, huge), (.html, sampleHTML), (.string, Data("Plain".utf8))], to: board)
        await service.poll()
        let entry = try #require(store.database.clipboard.first)
        #expect(entry.plainText == "Plain")
        #expect(entry.richText == ClipboardRichText(html: sampleHTML))
        #expect(ClipboardRichText.capture(rtf: huge, html: nil) == nil)
        #expect(ClipboardRichText.capture(rtf: Data(), html: Data()) == nil)
    }

    @Test func privacyMarkersStillSkipRichCopies() async {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, board: board)
        write(
            [
                (.rtf, sampleRTF), (.string, Data("secret".utf8)),
                (.init("org.nspasteboard.ConcealedType"), Data()),
            ], to: board)
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
    }

    // MARK: Paste As

    @Test func copyWritesTheRequestedFormatOnly() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, board: board)
        var entry = ClipboardEntry(text: "Bold text", sourceName: "Fixture")
        entry.richText = ClipboardRichText(rtf: sampleRTF, html: sampleHTML)

        #expect(service.copy(entry))
        #expect(board.data(forType: .rtf) == sampleRTF)
        #expect(board.data(forType: .html) == sampleHTML)
        #expect(board.string(forType: .string) == "Bold text")
        #expect(board.types?.contains(.init("com.openray.generated")) == true)

        #expect(service.copy(entry, as: .plainText))
        #expect(board.data(forType: .rtf) == nil && board.data(forType: .html) == nil)
        #expect(board.string(forType: .string) == "Bold text")

        #expect(service.copy(entry, as: .html))
        #expect(board.data(forType: .html) == sampleHTML && board.data(forType: .rtf) == nil)

        let plain = ClipboardEntry(text: "Plain", sourceName: "Fixture")
        let before = board.changeCount
        #expect(!service.copy(plain, as: .rtf))
        #expect(service.lastCopyError?.contains("isn't available") == true)
        #expect(board.changeCount == before)
    }

    @Test func copiesMarkedAsOpenRaysOwnAreNeverCaptured() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, board: board)
        // Written by another writer, so the service sees a new change count each time.
        write([(.rtf, sampleRTF), (.string, Data("Tagged".utf8)), (.init("com.openray.generated"), Data("1".utf8))], to: board)
        await service.poll()
        #expect(store.database.clipboard.isEmpty)
        write([(.rtf, sampleRTF), (.string, Data("Untagged".utf8))], to: board)
        await service.poll()
        #expect(store.database.clipboard.map(\.plainText) == ["Untagged"])
        #expect(store.database.clipboard.first?.richText?.rtf == sampleRTF)
    }

    @Test func formattingComesOnlyFromTheItemTheTextCameFrom() async throws {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let store = makeStore()
        let service = makeService(store: store, board: board)
        let plain = NSPasteboardItem()
        plain.setString("First item", forType: .string)
        let rich = NSPasteboardItem()
        rich.setString("Second item", forType: .string)
        rich.setData(sampleHTML, forType: .html)
        rich.setData(sampleRTF, forType: .rtf)
        board.clearContents()
        #expect(board.writeObjects([plain, rich]))
        await service.poll()
        // AppKit joins the plain text of all items; that text matches neither item's
        // formatting, so none is attached.
        let entry = try #require(store.database.clipboard.first)
        #expect(entry.plainText?.hasPrefix("First item") == true)
        #expect(entry.richText == nil)

        #expect(ClipboardService.richText(matching: Data("Second item".utf8), in: [rich]) == ClipboardRichText(rtf: sampleRTF, html: sampleHTML))
        #expect(ClipboardService.richText(matching: Data("Other".utf8), in: [rich]) == nil)
    }

    @Test func defaultServicesNeverUseTheRealClipboard() {
        #expect(SideEffectGuard.isInert)
        #expect(!ClipboardService(store: makeStore()).usesGeneralPasteboard)
        #expect(!ClipboardService(store: makeStore(), pasteboard: .general).usesGeneralPasteboard)
        #expect(!LauncherModel(store: LibraryStore(fileURL: nil)).clipboard.usesGeneralPasteboard)
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func inertModesIsolateTheGeneralPasteboard(_ mode: SideEffectGuard.Mode) {
        let sideEffects = SideEffectGuard(mode: mode)
        let service = ClipboardService(store: makeStore(), pasteboard: .general, sideEffects: sideEffects)
        #expect(!service.usesGeneralPasteboard)
        // The private board it got instead works normally.
        #expect(service.copy("Private"))
        #expect(service.readText() == "Private")
        let named = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { named.releaseGlobally() }
        #expect(ClipboardService.pasteboard(for: named, sideEffects: sideEffects) === named)
        #expect(!sideEffects.mayWrite(to: .general))
    }

    @Test func placeholderTextFollowsTheCapturePrivacyRules() {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        write([(.string, Data("Visible".utf8))], to: board)
        #expect(ClipboardPolicy.placeholderText(from: board) == "Visible")
        write([(.string, Data("Mine".utf8)), (.init("com.openray.generated"), Data("1".utf8))], to: board)
        #expect(ClipboardPolicy.placeholderText(from: board) == "Mine")
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            write([(.string, Data("secret".utf8)), (.init(marker), Data())], to: board)
            #expect(ClipboardPolicy.placeholderText(from: board) == nil, "\(marker)")
        }
        write([(.png, Data([1]))], to: board)
        #expect(ClipboardPolicy.placeholderText(from: board) == nil)
    }

    @Test func editingTextDropsStaleFormatting() {
        var entry = ClipboardEntry(text: "Bold", sourceName: "F")
        entry.richText = ClipboardRichText(rtf: sampleRTF)
        entry.replaceText("Edited")
        #expect(entry.plainText == "Edited" && entry.richText == nil)
    }

    @Test func copyFormattedTextDirectly() {
        let board = NSPasteboard(name: .init("OpenRayTests.\(UUID())"))
        defer { board.releaseGlobally() }
        let service = makeService(store: makeStore(), board: board)
        #expect(service.copy("Hi", richText: ClipboardRichText(rtf: sampleRTF)))
        #expect(board.data(forType: .rtf) == sampleRTF && board.string(forType: .string) == "Hi")
        #expect(!service.copy("Hi", richText: nil, as: .html))
        #expect(service.lastCopyError != nil)
    }

    @Test func payloadsPutTheRichestRepresentationFirst() throws {
        var entry = ClipboardEntry(text: "Bold text", sourceName: "Fixture")
        entry.richText = ClipboardRichText(rtf: sampleRTF, html: sampleHTML)
        let original = try #require(ClipboardPayload.items(for: entry, format: .original))
        #expect(original.count == 1)
        #expect(
            original[0].map(\.type) == [
                ClipboardRepresentation.rtfType, ClipboardRepresentation.htmlType, ClipboardRepresentation.plainTextType,
            ])
        #expect(ClipboardPayload.items(for: entry, format: .rtf)?[0].map(\.type) == ["public.rtf", "public.utf8-plain-text"])
        #expect(ClipboardPayload.items(for: entry, format: .plainText)?[0] == [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Bold text".utf8))])
        #expect(ClipboardPayload.formats(for: entry) == [.original, .plainText, .rtf, .html])
        #expect(ClipboardPayload.formats(for: ClipboardEntry(text: "x", sourceName: "F")) == [.original, .plainText])
        #expect(ClipboardPasteFormat.allCases.map(\.title).allSatisfy { $0.hasPrefix("Paste") })
    }

    @Test func imageAndFilePayloads() throws {
        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image()).image
        var picture = ClipboardEntry(content: .image(image), sourceName: "Fixture")
        #expect(ClipboardPayload.items(for: picture, format: .original) == nil)
        #expect(ClipboardPayload.items(for: picture, format: .original, imageData: Data([1, 2]))?[0] == [ClipboardRepresentation(type: "public.png", data: Data([1, 2]))])
        #expect(ClipboardPayload.items(for: picture, format: .plainText) == nil)
        picture.recognizedText = "Invoice 42"
        #expect(ClipboardPayload.items(for: picture, format: .plainText)?[0][0].data == Data("Invoice 42".utf8))
        #expect(ClipboardPayload.formats(for: picture) == [.original, .plainText])

        let files = ClipboardEntry(
            content: .files([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b c.txt")]), sourceName: "F")
        let items = try #require(ClipboardPayload.items(for: files, format: .original))
        #expect(items.count == 2)
        #expect(items[1] == [ClipboardRepresentation(type: "public.file-url", data: Data("file:///tmp/b%20c.txt".utf8))])
        #expect(ClipboardPayload.items(for: files, format: .plainText)?[0][0].data == Data("/tmp/a.txt\n/tmp/b c.txt".utf8))
        #expect(ClipboardPayload.items(for: files, format: .html) == nil)
    }

    // MARK: Storage

    @Test func formattingIsReferencedByDigestAndInlineOnlyUntilStored() throws {
        var entry = ClipboardEntry(text: "Bold", copiedAt: Date(timeIntervalSince1970: 100), sourceName: "Fixture")
        entry.richText = ClipboardRichText(rtf: sampleRTF, html: sampleHTML)
        // Without a side file yet, the formatting is saved inline, so it's never lost.
        let inline = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(entry))
        #expect(inline.richText == entry.richText && inline.richTextDigest == nil)
        // With one, only its digest is saved.
        entry.richTextDigest = String(repeating: "a", count: 64)
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(json.contains("richDigest") && !json.contains("\"rich\""))
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: Data(json.utf8))
        #expect(decoded.richText == nil && decoded.richTextDigest == entry.richTextDigest)
        entry.replaceText("Edited")
        #expect(entry.richText == nil && entry.richTextDigest == nil)

        let old = Data(#"{"id":"\#(UUID().uuidString)","kind":"text","text":"Old","copiedAt":0,"sourceName":"App"}"#.utf8)
        let older = try JSONDecoder().decode(ClipboardEntry.self, from: old)
        #expect(older.richText == nil && older.recognizedText == nil && older.plainText == "Old")
    }

    @Test func recognizedTextMakesImagesSearchable() throws {
        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image()).image
        var entry = ClipboardEntry(content: .image(image), sourceName: "Preview")
        entry.recognizedText = "Quarterly invoice"
        #expect(entry.searchableText.contains("Quarterly invoice"))
        #expect(entry.isValid)
        entry.recognizedText = String(repeating: "x", count: ClipboardLimits.recognizedTextBytes + 1)
        #expect(!entry.isValid)
    }

    @Test func richTextOnlyBelongsToTextEntries() throws {
        let image = try ClipboardImageCodec.prepare(ClipboardFixtures.image()).image
        var entry = ClipboardEntry(content: .image(image), sourceName: "F")
        entry.richText = ClipboardRichText(rtf: sampleRTF)
        #expect(!entry.isValid)
        var text = ClipboardEntry(text: "x", sourceName: "F")
        text.richText = ClipboardRichText(rtf: Data(repeating: 1, count: ClipboardLimits.richTextBytes + 1))
        #expect(!text.isValid)
    }

    // MARK: Kinds

    @Test(arguments: [
        ("#FF8800", "#FF8800"), ("#f80", "#FF8800"), ("#FF880080", "#FF880080"), ("#f808", "#FF880088"),
        ("rgb(255, 136, 0)", "#FF8800"), ("rgba(255,136,0,0.5)", "#FF880080"), ("rgb(255 136 0 / 50%)", "#FF880080"),
        ("RGB(100%, 0%, 0%)", "#FF0000"), ("hsl(120, 100%, 50%)", "#00FF00"), ("hsl(240deg 100% 50% / 0.5)", "#0000FF80"),
        ("hsla(0, 0%, 100%, 1)", "#FFFFFF"), ("  #000000\n", "#000000"),
    ])
    func colorsAreRecognized(_ text: String, _ hex: String) {
        let entry = ClipboardEntry(text: text, sourceName: "F")
        #expect(entry.textKind == .color)
        #expect(entry.color?.hexString == hex)
        #expect(entry.kindTitle == "Color")
        #expect(entry.symbol == "paintpalette")
    }

    @Test(arguments: [
        "#hashtag", "#12345", "rgb(300, 0, 0)", "hsl(1, 2, 3)", "red", "rgb(1, 2)", "rgba(1,2,3,2)", "#FF8800 and more",
        "rgb(1, 2, 3, 0.5 / 1)", "hsl(x, 1%, 1%)",
    ])
    func nonColorsAreNot(_ text: String) {
        #expect(ClipboardColor(parsing: text) == nil)
        #expect(ClipboardEntry(text: text, sourceName: "F").textKind != .color)
    }

    @Test func emailsAreRecognized() {
        for address in ["name@example.com", "first.last+tag@sub.example.co.uk", " a_b@x-y.io "] {
            let entry = ClipboardEntry(text: address, sourceName: "F")
            #expect(entry.textKind == .email, "\(address)")
            #expect(entry.kindTitle == "Email" && entry.symbol == "envelope")
        }
        for text in ["a@b", "a@@b.com", "a b@c.com", "@example.com", "name@.com", "name@example.c0m", "x.@y.com", "Write to a@b.com"] {
            #expect(!ClipboardTextKind.isEmailAddress(text), "\(text)")
        }
        // A mailto link stays a link, so the Links filter keeps finding it.
        #expect(ClipboardEntry(text: "mailto:a@b.com", sourceName: "F").textKind == .link)
        #expect(ClipboardEntry(text: "https://x.com", sourceName: "F").kindTitle == "Link")
        #expect(ClipboardEntry(text: "Plain words", sourceName: "F").kindTitle == "Text")
    }

    // MARK: Retention

    @Test func retentionChoicesMapFromSavedDays() {
        #expect(ClipboardRetention.default == .sevenDays)
        #expect(ClipboardRetentionPolicy().retention == .sevenDays)
        #expect(ClipboardRetention.default.days == AppPreferences().clipboardRetentionDays)
        #expect(ClipboardRetention.allCases.map(\.days) == [1, 7, 30, 90, nil])
        #expect(ClipboardRetention(days: 1) == .oneDay)
        #expect(ClipboardRetention(days: 0) == .oneDay)
        #expect(ClipboardRetention(days: 7) == .sevenDays)
        #expect(ClipboardRetention(days: 14) == .thirtyDays)
        #expect(ClipboardRetention(days: 90) == .threeMonths)
        #expect(ClipboardRetention(days: 365) == .unlimited)
        #expect(ClipboardRetention.allCases.map(\.title) == ["1 Day", "7 Days", "30 Days", "3 Months", "Unlimited"])
    }

    @Test func policyMatchesTheStoresPruning() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let day = 86_400.0
        var entries = (0..<8).map { index in
            ClipboardEntry(text: "Entry \(index)", copiedAt: now.addingTimeInterval(-Double(index) * 2 * day), sourceName: "F")
        }
        entries[6].isPinned = true
        let store = LibraryStore(fileURL: nil)
        store.update {
            $0.preferences.clipboardEnabled = true
            $0.preferences.clipboardRetentionDays = 7
            $0.preferences.clipboardLimit = 3
            $0.clipboard = entries
        }
        store.pruneClipboard(now: now)
        let policy = ClipboardRetentionPolicy(retention: .sevenDays, maximumItems: 3)
        let pruned = policy.prune(entries, now: now)
        #expect(pruned.map(\.id) == store.database.clipboard.map(\.id))
        #expect(pruned.map(\.text) == ["Entry 0", "Entry 1", "Entry 2", "Entry 6"])
    }

    @Test func unlimitedRetentionKeepsOldEntriesUpToTheCap() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        let entries = (0..<5).map { ClipboardEntry(text: "E\($0)", copiedAt: now.addingTimeInterval(-Double($0) * 400 * 86_400), sourceName: "F") }
        #expect(ClipboardRetentionPolicy(retention: .unlimited, maximumItems: 10).prune(entries, now: now).count == 5)
        #expect(ClipboardRetentionPolicy(retention: .unlimited, maximumItems: 2).prune(entries, now: now).map(\.text) == ["E0", "E1"])
        #expect(ClipboardRetentionPolicy(retention: .unlimited).cutoff(now: now) == nil)
        #expect(ClipboardRetentionPolicy(retention: .threeMonths).cutoff(now: now) == now.addingTimeInterval(-90 * 86_400))
        #expect(ClipboardRetentionPolicy(maximumItems: 0).maximumItems == 1)
        #expect(ClipboardRetentionPolicy(maximumItems: 1_000_000).maximumItems == 5_000)
    }

    @Test func pinnedEntriesClaimTheByteBudgetFirst() {
        let now = Date()
        var entries = [
            ClipboardEntry(text: String(repeating: "a", count: 40), copiedAt: now, sourceName: "F"),
            ClipboardEntry(text: String(repeating: "b", count: 40), copiedAt: now.addingTimeInterval(-10), sourceName: "F"),
            ClipboardEntry(text: String(repeating: "c", count: 40), copiedAt: now.addingTimeInterval(-20), sourceName: "F"),
        ]
        entries[2].isPinned = true
        let pruned = ClipboardRetentionPolicy(retention: .oneDay, maximumItems: 10, byteBudget: 100).prune(entries, now: now)
        #expect(pruned.map(\.text.first) == ["a", "c"])
    }
}
