import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OpenRay

/// Returns text derived from the file name and counts calls, instead of running Vision.
final class FakeScreenshotRecognizer: ImageTextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }

    func recognizeText(inImageAt url: URL, accurate: Bool) async throws -> String {
        lock.withLock { _calls.append(url.lastPathComponent) }
        return "text of \(url.deletingPathExtension().lastPathComponent)\(accurate ? " (accurate)" : "")"
    }
}

@MainActor
struct ScreenshotsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayShots-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.standardizedFileURL
    }

    /// Writes a small generated PNG with the given dates.
    @discardableResult
    private func image(_ name: String, in folder: URL, created: Date, size: Int = 8) throws -> URL {
        let url = folder.appending(path: name)
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let cgImage = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
        return url
    }

    private func index(_ folder: URL, includesAll: Bool = false, recognizer: FakeScreenshotRecognizer) -> ScreenshotIndex {
        ScreenshotIndex(recognizer: recognizer, sideEffects: SideEffectGuard(mode: .testHost)) { _ in
            [ScreenshotFolder(url: folder, includesAllImages: includesAll)]
        }
    }

    // MARK: Filters

    @Test func filtersParseTextNameDateAndFreeWords() {
        let now = date(2026, 11, 26, 15)
        let filter = ScreenshotFilter.parse("text:invoice name:receipt date:today total", now: now, calendar: calendar)
        #expect(filter.text == ["invoice"])
        #expect(filter.name == ["receipt"])
        #expect(filter.free == ["total"])
        #expect(filter.dates == calendar.dateInterval(of: .day, for: now))
        #expect(ScreenshotFilter.parse("text:\"net total\" Name:Q4", now: now, calendar: calendar).text == ["net total"])
        #expect(ScreenshotFilter.parse("text:\"net total\" Name:Q4", now: now, calendar: calendar).name == ["Q4"])
        #expect(ScreenshotFilter.parse("", now: now, calendar: calendar).isEmpty)
        #expect(ScreenshotFilter.parse("text:", now: now, calendar: calendar).isEmpty)
    }

    @Test func dateFiltersUnderstandDaysAndWeeks() {
        let now = date(2026, 11, 26, 15)
        func day(_ value: String) -> Date? {
            ScreenshotFilter.dateInterval(value, now: now, calendar: calendar)?.start
        }
        #expect(day("today") == calendar.startOfDay(for: now))
        #expect(day("Yesterday") == calendar.startOfDay(for: date(2026, 11, 25)))
        #expect(day("2026-11-03") == calendar.startOfDay(for: date(2026, 11, 3)))
        #expect(day("03.11.2026") == calendar.startOfDay(for: date(2026, 11, 3)))
        #expect(day("Nov 3") == calendar.startOfDay(for: date(2026, 11, 3)))
        #expect(day("3 November 2025") == calendar.startOfDay(for: date(2025, 11, 3)))
        // A day still to come this year means last year's.
        #expect(day("Dec 24") == calendar.startOfDay(for: date(2025, 12, 24)))
        #expect(ScreenshotFilter.dateInterval("last week", now: now, calendar: calendar)?.contains(date(2026, 11, 18)) == true)
        // The phrase works unquoted, as the empty state suggests it.
        let unquoted = ScreenshotFilter.parse("date:last week invoice", now: now, calendar: calendar)
        #expect(!unquoted.hasInvalidDate)
        #expect(unquoted.dates?.contains(date(2026, 11, 18)) == true)
        #expect(unquoted.free == ["invoice"])
        #expect(ScreenshotFilter.parse("date:\"this month\"", now: now, calendar: calendar).dates?.contains(date(2026, 11, 1)) == true)
        #expect(ScreenshotFilter.dateInterval("this month", now: now, calendar: calendar)?.contains(date(2026, 11, 1)) == true)
        #expect(day("someday") == nil)
        let invalid = ScreenshotFilter.parse("date:someday", now: now, calendar: calendar)
        #expect(invalid.hasInvalidDate)
        #expect(!invalid.matches(ScreenshotRecord(path: "/a.png", name: "a.png", createdAt: now, modifiedAt: now, byteCount: 1)))
    }

    @Test func filtersMatchNamesTextAndDates() {
        let now = date(2026, 11, 26, 15)
        let record = ScreenshotRecord(
            path: "/s/Screenshot receipt.png", name: "Screenshot receipt.png", createdAt: date(2026, 11, 25, 9),
            modifiedAt: now, byteCount: 1, text: "Invoice 42\nNet total €12")
        func matches(_ query: String) -> Bool { ScreenshotFilter.parse(query, now: now, calendar: calendar).matches(record) }
        #expect(matches("receipt"))
        #expect(matches("invoice"))
        #expect(matches("text:\"net total\""))
        #expect(matches("name:receipt date:yesterday"))
        #expect(!matches("name:invoice"))
        #expect(!matches("text:receipt"))
        #expect(!matches("date:today"))
        #expect(matches("text:INVOICE"))
        // With text recognition off, recognized text isn't searched.
        #expect(!ScreenshotFilter.parse("invoice", now: now, calendar: calendar).matches(record, usingText: false))
        #expect(ScreenshotFilter.parse("receipt", now: now, calendar: calendar).matches(record, usingText: false))
    }

    // MARK: Index

    @Test func indexingFindsScreenshotsRecognizesTextAndPersists() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try image("Screenshot 2026-11-24 at 09.00.00.png", in: folder, created: date(2026, 11, 24))
        try image("Screenshot 2026-11-25 at 10.00.00.png", in: folder, created: date(2026, 11, 25))
        try image("holiday.png", in: folder, created: date(2026, 11, 20))
        try Data("not an image".utf8).write(to: folder.appending(path: "notes.txt"))
        let recognizer = FakeScreenshotRecognizer()
        let saved = folder.appending(path: "store/screenshots.json")
        let index = index(folder, recognizer: recognizer)
        index.load(from: saved)

        await index.refresh()
        #expect(index.records.map(\.name) == ["Screenshot 2026-11-25 at 10.00.00.png", "Screenshot 2026-11-24 at 09.00.00.png"])
        await index.waitForRecognition()
        #expect(index.records.map(\.text) == ["text of Screenshot 2026-11-25 at 10.00.00", "text of Screenshot 2026-11-24 at 09.00.00"])
        #expect(index.pendingRecognition == 0)
        #expect(index.matching("text:\"11-24\"").map(\.name) == ["Screenshot 2026-11-24 at 09.00.00.png"])

        // The index lives in its own file, read back by a new index.
        let reloaded = ScreenshotIndex(recognizer: recognizer, sideEffects: SideEffectGuard(mode: .testHost)) { _ in [] }
        reloaded.load(from: saved)
        #expect(reloaded.records == index.records)
        let permissions = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // A new screenshot joins; text already read isn't read again.
        try image("Screenshot 2026-11-26 at 08.00.00.png", in: folder, created: date(2026, 11, 26))
        await index.refresh()
        await index.waitForRecognition()
        #expect(index.latest?.name == "Screenshot 2026-11-26 at 08.00.00.png")
        #expect(recognizer.calls.count == 3)

        // A changed file is read again; a removed one leaves the index.
        try image("Screenshot 2026-11-24 at 09.00.00.png", in: folder, created: date(2026, 11, 24), size: 16)
        try FileManager.default.removeItem(at: folder.appending(path: "Screenshot 2026-11-25 at 10.00.00.png"))
        await index.refresh()
        await index.waitForRecognition()
        #expect(index.records.map(\.name) == ["Screenshot 2026-11-26 at 08.00.00.png", "Screenshot 2026-11-24 at 09.00.00.png"])
        #expect(recognizer.calls.count == 4)
        #expect(index.records.allSatisfy { record in record.text != nil })
    }

    @Test func extraFoldersIndexEveryImage() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try image("holiday.png", in: folder, created: date(2026, 11, 20))
        try image("Screenshot one.png", in: folder, created: date(2026, 11, 21))
        let index = index(folder, includesAll: true, recognizer: FakeScreenshotRecognizer())
        await index.refresh()
        #expect(Set(index.records.map(\.name)) == ["holiday.png", "Screenshot one.png"])
        index.stopRecognition()
    }

    @Test func retentionDropsOldScreenshotsFromTheIndexOnly() {
        let now = date(2026, 11, 26)
        let scanned = [
            ScannedImage(url: URL(fileURLWithPath: "/s/new.png"), createdAt: date(2026, 11, 25), modifiedAt: now, byteCount: 1),
            ScannedImage(url: URL(fileURLWithPath: "/s/old.png"), createdAt: date(2026, 10, 1), modifiedAt: now, byteCount: 1),
        ]
        #expect(ScreenshotScanner.merge([], scanned: scanned, retentionDays: 7, now: now).map(\.name) == ["new.png"])
        #expect(ScreenshotScanner.merge([], scanned: scanned, retentionDays: nil, now: now).map(\.name) == ["new.png", "old.png"])
        // Unchanged files keep their text.
        let kept = ScreenshotRecord(
            path: "/s/new.png", name: "new.png", createdAt: date(2026, 11, 25), modifiedAt: now, byteCount: 1, text: "hello")
        #expect(ScreenshotScanner.merge([kept], scanned: scanned, retentionDays: 7, now: now).first?.text == "hello")
    }

    @Test func screenshotNamesAreRecognizedInSeveralLanguages() {
        #expect(ScreenshotScanner.isScreenshot(URL(fileURLWithPath: "/x/Screenshot 2026-11-26 at 10.00.00.png")))
        #expect(ScreenshotScanner.isScreenshot(URL(fileURLWithPath: "/x/Bildschirmfoto 2026-11-26 um 10.00.00.png")))
        #expect(ScreenshotScanner.isScreenshot(URL(fileURLWithPath: "/x/Screen Shot 2020-01-01 at 1.00.00 PM.png")))
        #expect(!ScreenshotScanner.isScreenshot(URL(fileURLWithPath: "/x/does-not-exist-holiday.png")))
    }

    @Test func theLiveIndexNeverReadsRealFoldersWhileInert() async {
        for mode in [SideEffectGuard.Mode.testHost, .verification] {
            let index = ScreenshotIndex(recognizer: FakeScreenshotRecognizer(), sideEffects: SideEffectGuard(mode: mode))
            #expect(index.folders(ScreenshotSettings()).isEmpty)
            await index.refresh()
            index.startWatching()
            #expect(index.records.isEmpty)
            #expect(index.isInert)
        }
        let folders = ScreenshotLocation.folders(
            settings: ScreenshotSettings(), system: URL(fileURLWithPath: "/Users/t/Pictures/Shots"),
            home: URL(fileURLWithPath: "/Users/t"))
        #expect(folders.map(\.url.path) == ["/Users/t/Pictures/Shots", "/Users/t/Desktop"])
        var settings = ScreenshotSettings()
        settings.watchesDesktop = false
        settings.extraFolders = ["/Volumes/Shots"]
        #expect(
            ScreenshotLocation.folders(settings: settings, system: URL(fileURLWithPath: "/Users/t/Desktop"), home: URL(fileURLWithPath: "/Users/t"))
                .map(\.url.path) == ["/Users/t/Desktop", "/Volumes/Shots"])
        // The Desktop added again as an extra folder keeps its every-image policy.
        var desktopTwice = ScreenshotSettings()
        desktopTwice.extraFolders = ["/Users/t/Desktop"]
        let merged = ScreenshotLocation.folders(
            settings: desktopTwice, system: URL(fileURLWithPath: "/Users/t/Pictures"), home: URL(fileURLWithPath: "/Users/t"))
        #expect(merged.map(\.url.path) == ["/Users/t/Pictures", "/Users/t/Desktop"])
        #expect(merged.last?.includesAllImages == true)
    }

    @Test func screenshotSettingsRoundTrip() {
        var settings = ScreenshotSettings()
        #expect(settings.values.isEmpty)
        settings.extraFolders = ["~/Shots"]
        settings.includesAllImages = true
        settings.recognizesText = false
        settings.accurateRecognition = true
        settings.columns = 6
        settings.retentionDays = 30
        settings.watchesDesktop = false
        #expect(ScreenshotSettings(settings.values) == settings)
        #expect(ScreenshotSettings(["columns": "9", "retentionDays": "12"]).columns == ScreenshotSettings.defaultColumns)
        #expect(ScreenshotSettings(["retentionDays": "12"]).retentionDays == nil)
    }

    // MARK: Scope and commands

    private func setUp(_ folder: URL, pasteboard: NSPasteboard) async -> (LauncherModel, ScreenshotsCommandProvider, FakeFileWorkspace) {
        let workspace = FakeFileWorkspace()
        let provider = ScreenshotsCommandProvider(
            index: index(folder, recognizer: FakeScreenshotRecognizer()), workspace: workspace)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: pasteboard,
            registry: CommandRegistry(providers: [provider]))
        await provider.index.refresh()
        await provider.index.waitForRecognition()
        return (model, provider, workspace)
    }

    @Test func theScopeIsAGridGroupedByDayWithAdjustableColumns() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = Calendar.current.startOfDay(for: .now)
        try image("Screenshot a.png", in: folder, created: today.addingTimeInterval(120))
        try image("Screenshot b.png", in: folder, created: today.addingTimeInterval(60))
        try image("Screenshot c.png", in: folder, created: today.addingTimeInterval(-86_400 * 40))
        let (model, _, _) = await setUp(folder, pasteboard: .withUniqueName())
        let command = try #require(model.commandItems.first { $0.id == ScreenshotsCommandProvider.searchID })
        model.perform(command)
        #expect(model.section.providedScope?.id == ScreenshotsCommandProvider.scope.id)
        let groups = model.groups
        #expect(groups.count == 2)
        #expect(groups.first?.title == "Today")
        #expect(groups.allSatisfy { $0.style == .grid && $0.columns == 4 && $0.tile != nil })
        #expect(groups.flatMap(\.items).map(\.title) == ["Screenshot a.png", "Screenshot b.png", "Screenshot c.png"])
        #expect(model.arrowsMoveSelection)

        // ⌘- makes tiles smaller (more columns); ⌘+ larger; ⌘0 resets. Limits hold.
        try #require(model.actions(for: model.selectedItem).first { $0.id == "smallerTiles" }).perform()
        #expect(model.groups.first?.columns == 5)
        model.setScreenshotColumns(9)
        #expect(model.screenshotSettings.columns == 6)
        #expect(!model.actions(for: model.selectedItem).contains { $0.id == "smallerTiles" })
        try #require(model.actions(for: model.selectedItem).first { $0.id == "defaultTiles" }).perform()
        #expect(model.groups.first?.columns == 4)

        // Filters narrow the grid.
        model.query = "text:\"text of Screenshot b\""
        #expect(model.orderedResults.map(\.title) == ["Screenshot b.png"])
        model.query = "name:zzz"
        #expect(model.orderedResults.isEmpty)
        #expect(model.providedEmptyState(for: ScreenshotsCommandProvider.scope).title.hasPrefix("No screenshots match"))
        model.query = "date:someday"
        #expect(model.providedEmptyState(for: ScreenshotsCommandProvider.scope).title == "OpenRay can't read that date")
    }

    @Test func copyLatestPutsTheImageItselfOnThePrivateClipboard() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try image("Screenshot old.png", in: folder, created: date(2026, 11, 20))
        let newest = try image("Screenshot new.png", in: folder, created: date(2026, 11, 25))
        let pasteboard = NSPasteboard.withUniqueName()
        let (model, _, _) = await setUp(folder, pasteboard: pasteboard)
        let command = try #require(model.commandItems.first { $0.id == ScreenshotsCommandProvider.copyLatestID })
        model.perform(command)
        try await waitFor { pasteboard.pasteboardItems?.isEmpty == false }
        let item = try #require(pasteboard.pasteboardItems?.first)
        // Real image data, so apps that only take pictures can paste it, and the file for the rest.
        #expect(item.data(forType: .png) == (try Data(contentsOf: newest)))
        #expect(item.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL.path == newest.path)
        #expect(model.feedback?.text == "Copied “Screenshot new.png”")
    }

    @Test func pasteLatestGoesWhereItWasInvokedOrOnlyCopies() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try image("Screenshot one.png", in: folder, created: date(2026, 11, 25))
        let pasteboard = NSPasteboard.withUniqueName()
        let (model, provider, _) = await setUp(folder, pasteboard: pasteboard)
        let editor = ScreenshotsCommandProvider.PasteDestination(pid: 501, name: "Editor", launchDate: nil)
        let chat = ScreenshotsCommandProvider.PasteDestination(pid: 502, name: "Chat", launchDate: nil)
        final class Box<Value> { var value: Value; init(_ value: Value) { self.value = value } }
        let pastedBox = Box<[ScreenshotsCommandProvider.PasteDestination]>([])
        let frontBox = Box<pid_t>(501)
        var pasted: [ScreenshotsCommandProvider.PasteDestination] { pastedBox.value }
        provider.destination = { _ in editor }
        provider.frontmostPID = { frontBox.value }
        provider.canPasteAcrossApps = { _ in true }
        provider.pasteInto = { destination, _ in pastedBox.value.append(destination) }
        let command = try #require(model.commandItems.first { $0.id == ScreenshotsCommandProvider.pasteLatestID })

        // The destination is captured when the command runs, before the scan awaits.
        model.perform(command)
        provider.destination = { _ in chat }
        try await waitFor { !pasted.isEmpty }
        #expect(pasted == [editor])
        #expect(pasteboard.pasteboardItems?.first?.data(forType: .png) != nil)

        // The person moved to another app during the scan: copy only, and say so.
        provider.destination = { _ in editor }
        frontBox.value = 777
        model.perform(command)
        try await waitFor { model.feedback?.text.contains("isn't in front anymore") == true }
        #expect(pasted == [editor])

        // A newer request supersedes one still scanning; only the newer one acts.
        frontBox.value = 501
        model.perform(command)
        model.perform(command)
        try await waitFor { pasted.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(pasted.count == 2)
    }

    @Test func turningTextRecognitionOffHidesRecognizedText() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try image("Screenshot receipt.png", in: folder, created: date(2026, 11, 25))
        let (model, provider, _) = await setUp(folder, pasteboard: .withUniqueName())
        model.navigate(to: .provided(ScreenshotsCommandProvider.scope))
        model.query = "text of"
        #expect(model.orderedResults.count == 1)
        #expect(model.actions(for: model.orderedResults.first).contains { $0.id == "copyText" })
        model.updateScreenshotSettings { $0.recognizesText = false }
        #expect(model.orderedResults.isEmpty)
        model.query = ""
        #expect(!model.actions(for: model.selectedItem).contains { $0.id == "copyText" })
        #expect(provider.index.records.first?.version.isEmpty == false)
    }

    @Test func screenshotActionsCopyTextAndMoveToTrash() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shot = try image("Screenshot receipt.png", in: folder, created: date(2026, 11, 25))
        let pasteboard = NSPasteboard.withUniqueName()
        let (model, provider, workspace) = await setUp(folder, pasteboard: pasteboard)
        model.navigate(to: .provided(ScreenshotsCommandProvider.scope))
        let item = try #require(model.selectedItem)
        #expect(model.primaryTitle(for: item) == "Copy Image")
        #expect(model.secondaryTitle(for: item)?.hasPrefix("Paste Image to") == true)
        let entries = model.actions(for: item)
        for id in ["quickLook", "open", "reveal", "copyText", "copyPath", "trash"] { #expect(entries.contains { $0.id == id }) }
        try #require(entries.first { $0.id == "copyText" }).perform()
        #expect(pasteboard.string(forType: .string) == "text of Screenshot receipt")

        try #require(entries.first { $0.id == "trash" }).perform()
        #expect(workspace.trashed.isEmpty)
        model.performSelected()
        #expect(workspace.trashed == [shot])
        #expect(provider.index.records.isEmpty)
    }
}
