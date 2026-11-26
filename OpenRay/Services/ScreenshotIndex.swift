import AppKit
import ImageIO
import Observation

// MARK: - Text recognition

/// Reads the text in an image file. The screenshot index's seam, so tests use a fake.
protocol ImageTextRecognizing: Sendable {
    func recognizeText(inImageAt url: URL, accurate: Bool) async throws -> String
}

/// Screenshot OCR on the shared on-device recognizer (`Core/TextRecognition.swift`), with
/// Fast or Accurate as Settings › Screenshots chooses. Nothing leaves this Mac, and while
/// inert it reads fixtures only.
struct ScreenshotTextRecognizer: ImageTextRecognizing {
    var recognizer: any TextRecognizing = VisionTextRecognizer()

    func recognizeText(inImageAt url: URL, accurate: Bool) async throws -> String {
        try InertReadBoundary.check(url)
        let options = TextRecognitionOptions(level: accurate ? .accurate : .fast, usesLanguageCorrection: accurate)
        return try await recognizer.recognizeText(inImageAt: url, options: options).text
    }
}

/// An image file as PNG data, for the clipboard: PNG files as they are, other formats
/// converted. Nil for unreadable or oversized images, and outside fixtures while inert.
enum ScreenshotImageData {
    static let maximumBytes = 64_000_000
    static let maximumPixels = 40_000_000

    static func png(at url: URL, sideEffects: SideEffectGuard = .current) -> Data? {
        // `allows` floors the rule at this process's own, so a passed live rule can't widen it.
        guard InertReadBoundary.allows(url, sideEffects: sideEffects),
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= maximumBytes,
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0, width <= maximumPixels / height
        else { return nil }
        if CGImageSourceGetType(source) as String? == "public.png" { return try? Data(contentsOf: url) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - Settings

/// Settings › Screenshots, kept in `commandPreferences[ScreenshotSettings.key]`.
struct ScreenshotSettings: Equatable, Sendable {
    static let key = "settings.screenshots"
    static let columnRange = 3...6
    static let defaultColumns = 4
    /// Days the index keeps a screenshot; nil keeps everything. Files are never deleted.
    static let retentionChoices: [Int?] = [7, 30, 90, 180, 365, nil]

    var extraFolders: [String] = []
    /// Index every image in the watched folders, not only screenshots.
    var includesAllImages = false
    var recognizesText = true
    var accurateRecognition = false
    var columns = ScreenshotSettings.defaultColumns
    var retentionDays: Int? = nil
    /// Also watch the Desktop when screenshots are saved somewhere else.
    var watchesDesktop = true

    init() {}

    init(_ values: [String: String]?) {
        let values = values ?? [:]
        extraFolders = PreferenceValues.list(values["folders"])
        includesAllImages = PreferenceValues.flag(values["allImages"], default: false)
        recognizesText = PreferenceValues.flag(values["recognizeText"], default: true)
        accurateRecognition = PreferenceValues.flag(values["accurate"], default: false)
        watchesDesktop = PreferenceValues.flag(values["desktop"], default: true)
        if let columns = values["columns"].flatMap(Int.init), Self.columnRange.contains(columns) {
            self.columns = columns
        }
        if let days = values["retentionDays"].flatMap(Int.init), Self.retentionChoices.contains(days) {
            retentionDays = days
        }
    }

    var values: [String: String] {
        var values: [String: String] = [:]
        values["folders"] = PreferenceValues.string(extraFolders)
        if includesAllImages { values["allImages"] = "true" }
        if !recognizesText { values["recognizeText"] = "false" }
        if accurateRecognition { values["accurate"] = "true" }
        if !watchesDesktop { values["desktop"] = "false" }
        if columns != Self.defaultColumns { values["columns"] = String(columns) }
        if let retentionDays { values["retentionDays"] = String(retentionDays) }
        return values
    }

    static func retentionTitle(_ days: Int?) -> String {
        switch days {
        case nil: "Forever"
        case 7: "1 Week"
        case 30: "1 Month"
        case 90: "3 Months"
        case 180: "6 Months"
        case 365: "1 Year"
        case let days?: "\(days) Days"
        }
    }
}

// MARK: - Records

/// One indexed screenshot. The image stays where it is; the index holds its text and dates.
struct ScreenshotRecord: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var byteCount: Int
    /// Recognized text. Nil until recognition has run.
    var text: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    /// Changes when the file does, so thumbnails and actions never show an older image.
    var version: String { "\(modifiedAt.timeIntervalSinceReferenceDate)-\(byteCount)" }
}

/// A file a folder scan found.
struct ScannedImage: Equatable, Sendable {
    var url: URL
    var createdAt: Date
    var modifiedAt: Date
    var byteCount: Int
}

/// A watched folder, and whether every image in it counts or only screenshots.
struct ScreenshotFolder: Equatable, Sendable {
    var url: URL
    var includesAllImages: Bool
}

// MARK: - Filters

/// A Search Screenshots query: `text:invoice name:receipt date:yesterday` plus free words,
/// which match the name or the recognized text. Values can be quoted: `text:"net total"`.
struct ScreenshotFilter: Equatable, Sendable {
    var text: [String] = []
    var name: [String] = []
    var free: [String] = []
    /// The days `date:` allows. Nil when there's no date filter.
    var dates: DateInterval?
    /// True when `date:` had a value OpenRay couldn't read, so nothing matches.
    var hasInvalidDate = false

    var isEmpty: Bool { text.isEmpty && name.isEmpty && free.isEmpty && dates == nil && !hasInvalidDate }

    static func parse(_ query: String, now: Date = .now, calendar: Calendar = .current) -> ScreenshotFilter {
        var filter = ScreenshotFilter()
        var tokens = QueryTokenizer.tokens(query, keys: ["text", "name", "date"])
        // `date:last week` without quotes: the phrase continues into the next word.
        var index = 0
        while index + 1 < tokens.count {
            if tokens[index].key == "date", ["last", "this"].contains(tokens[index].text.lowercased()),
                tokens[index + 1].key == nil, ["week", "month"].contains(tokens[index + 1].text.lowercased())
            {
                tokens[index].text += " " + tokens[index + 1].text
                tokens.remove(at: index + 1)
            }
            index += 1
        }
        for token in tokens {
            switch token.key {
            case "text": if !token.text.isEmpty { filter.text.append(token.text) }
            case "name": if !token.text.isEmpty { filter.name.append(token.text) }
            case "date":
                guard !token.text.isEmpty else { continue }
                if let interval = dateInterval(token.text, now: now, calendar: calendar) {
                    filter.dates = interval
                } else {
                    filter.hasInvalidDate = true
                }
            default: if !token.text.isEmpty { filter.free.append(token.text) }
            }
        }
        return filter
    }

    /// `today`, `yesterday`, `this week`, `last week`, `this month`, or a day such as
    /// `2026-11-26`, `26.11.2026`, `11/26`, `Nov 26` or `26 November 2026`.
    static func dateInterval(_ value: String, now: Date, calendar: Calendar) -> DateInterval? {
        let value = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        let today = calendar.startOfDay(for: now)
        func day(_ start: Date) -> DateInterval? { calendar.dateInterval(of: .day, for: start) }
        switch value.lowercased() {
        case "today": return day(today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today).flatMap(day)
        case "this week", "thisweek", "week": return calendar.dateInterval(of: .weekOfYear, for: now)
        case "last week", "lastweek":
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now).flatMap {
                calendar.dateInterval(of: .weekOfYear, for: $0)
            }
        case "this month", "thismonth", "month": return calendar.dateInterval(of: .month, for: now)
        default: break
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        let year = calendar.component(.year, from: now)
        for format in ["yyyy-MM-dd", "dd.MM.yyyy", "MM/dd/yyyy", "MMM d yyyy", "d MMM yyyy", "MMMM d yyyy", "d MMMM yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return day(date) }
        }
        // Without a year: this year's date, or last year's when that's still to come.
        for format in ["MM/dd", "MMM d", "d MMM", "MMMM d", "d MMMM", "dd.MM"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: value) else { continue }
            var components = calendar.dateComponents([.month, .day], from: parsed)
            components.year = year
            guard var date = calendar.date(from: components) else { continue }
            if date > now { date = calendar.date(byAdding: .year, value: -1, to: date) ?? date }
            return day(date)
        }
        return nil
    }

    /// Whether a screenshot matches. With text recognition off, recognized text isn't searched.
    func matches(_ record: ScreenshotRecord, usingText: Bool = true) -> Bool {
        if hasInvalidDate { return false }
        if let dates, !dates.contains(record.createdAt) { return false }
        let recognized = usingText ? record.text ?? "" : ""
        func contains(_ haystack: String, _ needle: String) -> Bool {
            haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        guard name.allSatisfy({ contains(record.name, $0) }), text.allSatisfy({ contains(recognized, $0) }) else {
            return false
        }
        return free.allSatisfy { contains(record.name, $0) || contains(recognized, $0) }
    }
}

// MARK: - Scanning and merging

enum ScreenshotScanner {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp"]
    /// What macOS names screenshots in common languages, for files without the capture marker.
    static let screenshotPrefixes = [
        "Screenshot", "Screen Shot", "Bildschirmfoto", "Capture d’écran", "Capture d'écran", "Schermafbeelding",
        "Captura de pantalla", "Captura de Tela", "Istantanea schermo", "Skärmavbild", "Skjermbilde", "Skærmbillede",
        "Näyttökuva", "Zrzut ekranu", "Снимок экрана", "スクリーンショット", "截屏", "螢幕截圖", "스크린샷",
    ]
    /// The extended attribute macOS sets on screen captures.
    static let captureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Whether a file looks like a screen capture: the capture marker, or a screenshot name.
    static func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if screenshotPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return getxattr(url.path, captureAttribute, nil, 0, 0, 0) > 0
    }

    /// The images directly inside each folder (not its subfolders). Unreadable folders are skipped.
    static func scan(
        _ folders: [ScreenshotFolder], fileManager: FileManager = .default, sideEffects: SideEffectGuard = .current
    ) -> [ScannedImage] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var seen = Set<String>()
        var found: [ScannedImage] = []
        // Whatever folders are passed in, an inert run reads fixtures only.
        for folder in folders where InertReadBoundary.allows(folder.url, sideEffects: sideEffects) {
            guard
                let urls = try? fileManager.contentsOfDirectory(
                    at: folder.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for url in urls where imageExtensions.contains(url.pathExtension.lowercased()) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                    folder.includesAllImages || isScreenshot(url),
                    seen.insert(url.standardizedFileURL.path).inserted
                else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                found.append(
                    ScannedImage(
                        url: url.standardizedFileURL, createdAt: values.creationDate ?? modified, modifiedAt: modified,
                        byteCount: values.fileSize ?? 0))
            }
        }
        return found
    }

    /// Folds a scan into the index, newest first: new files join without text, changed files
    /// lose their old text, missing files leave, and screenshots older than the retention go.
    static func merge(
        _ records: [ScreenshotRecord], scanned: [ScannedImage], retentionDays: Int?, now: Date
    ) -> [ScreenshotRecord] {
        let existing = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let cutoff = retentionDays.map { now.addingTimeInterval(-TimeInterval($0) * 86_400) }
        return scanned.compactMap { image -> ScreenshotRecord? in
            if let cutoff, image.createdAt < cutoff { return nil }
            let path = image.url.path
            if let record = existing[path], record.modifiedAt == image.modifiedAt, record.byteCount == image.byteCount {
                return record
            }
            return ScreenshotRecord(
                path: path, name: image.url.lastPathComponent, createdAt: image.createdAt,
                modifiedAt: image.modifiedAt, byteCount: image.byteCount, text: nil)
        }
        .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.path < $1.path }
    }
}

/// Where macOS saves screenshots: the `location` the Screenshot app stores, or the Desktop.
enum ScreenshotLocation {
    static func system(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        guard
            let value = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString)
                as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return desktop }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The folders to watch for these settings: the system location, the Desktop, then extras.
    static func folders(settings: ScreenshotSettings, system: URL, home: URL) -> [ScreenshotFolder] {
        var folders = [ScreenshotFolder(url: system, includesAllImages: settings.includesAllImages)]
        let desktop = home.appending(path: "Desktop", directoryHint: .isDirectory)
        if settings.watchesDesktop {
            folders.append(ScreenshotFolder(url: desktop, includesAllImages: false))
        }
        for path in settings.extraFolders {
            folders.append(
                ScreenshotFolder(
                    url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
                    includesAllImages: true))
        }
        // A folder listed twice keeps the broader policy: every image if either says so.
        var merged: [ScreenshotFolder] = []
        for folder in folders {
            let path = folder.url.standardizedFileURL.path
            if let index = merged.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
                merged[index].includesAllImages = merged[index].includesAllImages || folder.includesAllImages
            } else {
                merged.append(folder)
            }
        }
        return merged
    }
}

// MARK: - Index

/// The screenshot index: a list kept in `screenshots.json` beside `library.json`, never in the
/// library. Scans run off the main thread, text recognition runs one image at a time in the
/// background, and the watched folders are observed only in a normal launch.
@MainActor
@Observable
final class ScreenshotIndex {
    private(set) var records: [ScreenshotRecord] = []
    private(set) var isScanning = false
    /// Images still waiting for text recognition.
    private(set) var pendingRecognition = 0
    private(set) var lastError: String?

    /// Settings › Screenshots, read at each scan.
    @ObservationIgnored var settings: @MainActor () -> ScreenshotSettings = { ScreenshotSettings() }
    /// The folders to scan. The live source returns none while inert, so tests and isolated
    /// verification never read the real screenshot folder; tests pass fixture folders.
    @ObservationIgnored var folders: @MainActor (ScreenshotSettings) -> [ScreenshotFolder]
    @ObservationIgnored var now: @MainActor () -> Date = { .now }
    @ObservationIgnored private(set) var fileURL: URL?
    @ObservationIgnored private let recognizer: any ImageTextRecognizing
    @ObservationIgnored private let sideEffects: SideEffectGuard
    @ObservationIgnored private var recognition: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var watchedPaths: [String] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var hasStartedWatching = false
    @ObservationIgnored private var recognitionPass: UUID?
    @ObservationIgnored private var lastRefreshAt: Date?

    nonisolated static let fileName = "screenshots.json"
    /// The index keeps at most this many screenshots, newest first.
    nonisolated static let limit = 5_000

    init(
        recognizer: any ImageTextRecognizing = ScreenshotTextRecognizer(), sideEffects: SideEffectGuard = .current,
        folders: (@MainActor (ScreenshotSettings) -> [ScreenshotFolder])? = nil
    ) {
        let sideEffects = SideEffectGuard.atLeastCurrent(sideEffects)
        self.recognizer = recognizer
        self.sideEffects = sideEffects
        self.folders =
            folders ?? { settings in
                guard !sideEffects.isInert else { return [] }
                let home = FileManager.default.homeDirectoryForCurrentUser
                return ScreenshotLocation.folders(settings: settings, system: ScreenshotLocation.system(home: home), home: home)
            }
    }

    /// The index file beside a library file, or nil to keep the index in memory.
    nonisolated static func fileURL(besideLibrary library: URL?) -> URL? {
        library?.deletingLastPathComponent().appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Reads the saved index once. A missing or unreadable file starts an empty index.
    func load(from fileURL: URL?) {
        self.fileURL = fileURL
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode(SavedIndex.self, from: data)
        else { return }
        records = saved.records
    }

    var latest: ScreenshotRecord? { records.first }
    /// True in the test host and isolated verification, where the real folders are never read.
    var isInert: Bool { sideEffects.isInert }

    func matching(_ query: String) -> [ScreenshotRecord] {
        let filter = ScreenshotFilter.parse(query, now: now())
        guard !filter.isEmpty else { return records }
        let usingText = settings().recognizesText
        return records.filter { filter.matches($0, usingText: usingText) }
    }

    /// Scans the watched folders, folds the result into the index, saves, and recognizes text.
    /// A call while a scan runs waits for a scan that starts after it.
    func refresh() async {
        if let scanTask {
            scanAgain = true
            await scanTask.value
            return
        }
        let task = Task {
            repeat {
                scanAgain = false
                await performRefresh()
            } while scanAgain
            scanTask = nil
        }
        scanTask = task
        await task.value
    }

    private func performRefresh() async {
        let settings = settings()
        let folders = folders(settings)
        lastRefreshAt = now()
        // The screenshot location can move; the watchers follow it.
        if hasStartedWatching { bind(folders.map(\.url.path)) }
        guard !folders.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }
        let sideEffects = self.sideEffects
        let scanned = await Task.detached(priority: .utility) { ScreenshotScanner.scan(folders, sideEffects: sideEffects) }.value
        let merged = ScreenshotScanner.merge(records, scanned: scanned, retentionDays: settings.retentionDays, now: now())
        let limited = Array(merged.prefix(Self.limit))
        if limited != records {
            records = limited
            save()
        }
        // Read again: recognition may have been turned off while the scan ran.
        let current = self.settings()
        if current.recognizesText { recognizePending(accurate: current.accurateRecognition) } else { stopRecognition() }
    }

    /// Drops every recognized text and recognizes again, for a changed accuracy setting.
    func reindex() async {
        stopRecognition()
        records = records.map { record in
            var record = record
            record.text = nil
            return record
        }
        save()
        await refresh()
    }

    /// Forgets one screenshot, after it was moved to the Trash.
    func remove(path: String) {
        records.removeAll { $0.path == path }
        save()
    }

    /// Recognizes text in the images that have none yet, newest first, one at a time.
    func recognizePending(accurate: Bool) {
        guard recognition == nil else { return }
        let recognizer = self.recognizer
        let pass = UUID()
        recognitionPass = pass
        recognition = Task { [weak self] in
            while let self, !Task.isCancelled, self.settings().recognizesText {
                let pending = self.records.filter { $0.text == nil }
                self.pendingRecognition = pending.count
                guard let next = pending.first else { break }
                let url = next.url
                // Called from this task, so cancelling the pass cancels the recognition in flight.
                let text = (try? await recognizer.recognizeText(inImageAt: url, accurate: accurate)) ?? ""
                // Turned off or cancelled meanwhile: the answer isn't kept.
                guard !Task.isCancelled, self.settings().recognizesText else { break }
                if let index = self.records.firstIndex(where: { $0.path == next.path && $0.modifiedAt == next.modifiedAt }) {
                    self.records[index].text = text
                    self.save()
                } else {
                    // Gone or changed meanwhile; the next scan sees it again.
                    self.records.removeAll { $0.path == next.path && $0.text == nil && $0.modifiedAt == next.modifiedAt }
                }
            }
            // Only this pass clears its handle; a newer pass keeps its own.
            guard let self, self.recognitionPass == pass else { return }
            self.pendingRecognition = self.records.filter { $0.text == nil }.count
            self.recognition = nil
        }
    }

    /// Waits for the running recognition pass, for tests and Paste Latest.
    func waitForRecognition() async {
        await recognition?.value
    }

    func stopRecognition() {
        recognition?.cancel()
        recognition = nil
        recognitionPass = nil
        pendingRecognition = 0
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(SavedIndex(records: records))
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            lastError = "The screenshot index couldn't be saved. \(error.localizedDescription)"
        }
    }

    private struct SavedIndex: Codable {
        var version = 1
        var records: [ScreenshotRecord]
    }

    // MARK: Watching

    /// Watches the folders for new and removed files, in a normal launch only, and rescans
    /// shortly after each change. Calling it again picks up changed folders.
    func startWatching() {
        guard !sideEffects.isInert else { return }
        hasStartedWatching = true
        bind(folders(settings()).map(\.url.path))
        Task { await refresh() }
    }

    /// Starts watching the first time Search Screenshots is used, and rescans when the last
    /// scan is more than a minute old. Cheap to call on every keystroke.
    func startWatchingIfNeeded() {
        guard hasStartedWatching else {
            startWatching()
            hasStartedWatching = true
            return
        }
        if !sideEffects.isInert, scanTask == nil, lastRefreshAt.map({ now().timeIntervalSince($0) > 60 }) ?? true {
            lastRefreshAt = now()
            Task { await refresh() }
        }
    }

    /// Points the watchers at these folders, unless they already are.
    private func bind(_ paths: [String]) {
        guard !sideEffects.isInert, paths != watchedPaths else { return }
        stopWatching()
        watchedPaths = paths
        for path in paths {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.folderDidChange() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    func stopWatching() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
        watchedPaths = []
    }

    private func folderDidChange() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.refresh()
        }
    }
}

// MARK: - Thumbnails

/// Downsampled previews for grid tiles, made off the main thread and kept for a while.
@MainActor
final class ScreenshotThumbnails {
    static let shared = ScreenshotThumbnails()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 300 }

    /// Keyed by path and file version, so a replaced screenshot never shows the old picture.
    private func key(_ url: URL, _ version: String) -> NSString { "\(url.path)#\(version)" as NSString }

    func cached(_ url: URL, version: String) -> NSImage? { cache.object(forKey: key(url, version)) }

    func thumbnail(for url: URL, version: String, maxPixels: Int = 480) async -> NSImage? {
        if let cached = cached(url, version: version) { return cached }
        guard InertReadBoundary.allows(url) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let image else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(thumbnail, forKey: key(url, version))
        return thumbnail
    }
}
