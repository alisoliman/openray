import AppKit
import SwiftUI

/// Search Screenshots: a grid of the screenshots in the watched folders, searchable by name,
/// date and the text inside them (`text:`, `name:`, `date:`), plus Copy and Paste Latest.
@MainActor
final class ScreenshotsCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "screenshots", bindablePrefixes: ["screenshots."]
    ) { ScreenshotsCommandProvider() }

    nonisolated static let searchID = "screenshots.search"
    nonisolated static let pasteLatestID = "screenshots.pasteLatest"
    nonisolated static let copyLatestID = "screenshots.copyLatest"

    static let scope = ProvidedScope(
        id: "screenshots.search", provider: "screenshots", title: "Search Screenshots", symbol: "camera.viewfinder",
        kind: .file, placeholder: "Search screenshots · text: name: date:",
        summary: "Find screenshots by name, date or the text inside", shortTitle: "Screenshots",
        itemNoun: "screenshot", style: .grid, ranksItems: false, columns: ScreenshotSettings.defaultColumns)

    /// The app a paste goes to, captured when the command runs.
    struct PasteDestination: Equatable {
        var pid: pid_t
        var name: String
        var launchDate: Date?
    }

    var id: String { Self.registration.id }
    let index: ScreenshotIndex
    let workspace: any FileWorkspace
    /// Where a paste would go right now: the app behind the panel while it shows, else the
    /// frontmost app. Read once per command, before anything awaits.
    var destination: @MainActor (LauncherModel) -> PasteDestination? = { model in
        let app = model.panel?.isVisible == true ? model.previousApplication : NSWorkspace.shared.frontmostApplication
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return PasteDestination(pid: app.processIdentifier, name: app.localizedName ?? "your app", launchDate: app.launchDate)
    }
    var frontmostPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// Whether a paste may reach another app: never with the isolated pasteboard.
    var canPasteAcrossApps: @MainActor (LauncherModel) -> Bool = { $0.clipboard.usesGeneralPasteboard }
    /// Sends ⌘V to the destination, once it's frontmost and the clipboard is unchanged.
    var pasteInto: @MainActor (PasteDestination, Int) async throws -> Void = { destination, changeCount in
        try SideEffectGuard.check("pasting into \(destination.name)")
        guard let app = NSRunningApplication(processIdentifier: destination.pid), !app.isTerminated,
            app.launchDate == destination.launchDate
        else { throw LibraryValidationError("\(destination.name) quit before the paste.") }
        try await SyntheticInput.paste(into: app, expectedChangeCount: changeCount)
    }
    /// The latest copy or paste request. An older one still scanning gives way to it.
    private var invocation = UUID()

    convenience init() {
        self.init(index: ScreenshotIndex(), workspace: LiveFileWorkspace())
    }

    init(index: ScreenshotIndex, workspace: any FileWorkspace) {
        self.index = index
        self.workspace = workspace
    }

    /// Loads the saved index beside the library and starts watching, in a normal launch only.
    func attach(to model: LauncherModel) {
        index.settings = { [weak model] in model?.screenshotSettings ?? ScreenshotSettings() }
        // A test or verification run never reads the real index beside the real library.
        let library = model.store.fileURL
        if !index.isInert || library != LibraryStore.defaultURL {
            index.load(from: ScreenshotIndex.fileURL(besideLibrary: library))
        }
        // Folders are read once Search Screenshots has been used, never before.
        if !index.records.isEmpty { index.startWatchingIfNeeded() }
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.searchID, title: "Search Screenshots", subtitle: Self.scope.summary, kind: .file,
                symbol: "camera.viewfinder", keywords: ["screenshot", "screen capture", "image", "ocr", "find"],
                mode: .view(.provided(Self.scope))),
            CommandDescriptor(
                id: Self.pasteLatestID, title: "Paste Latest Screenshot", subtitle: "Into the app you were using",
                kind: .file, symbol: "photo.on.rectangle", keywords: ["screenshot", "recent", "last", "image"],
                mode: .noView),
            CommandDescriptor(
                id: Self.copyLatestID, title: "Copy Latest Screenshot", subtitle: "To the clipboard", kind: .file,
                symbol: "doc.on.clipboard", keywords: ["screenshot", "recent", "last", "image"], mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.pasteLatestID, Self.copyLatestID:
            let pastes = ref.id == Self.pasteLatestID
            // The destination is fixed now, before the scan, so a paste can't land in an app the
            // person switched to meanwhile.
            let destination = pastes ? destination(model) : nil
            let request = UUID()
            invocation = request
            Task { [weak self, weak model] in
                guard let self, let model else { return }
                self.index.startWatchingIfNeeded()
                await self.index.refresh()
                guard self.invocation == request else { return }
                guard let latest = self.index.latest else {
                    model.feedback = .info("No screenshots yet. Take one with ⇧⌘3 or ⇧⌘4.")
                    return
                }
                model.store.recordUse(of: item.id)
                if pastes {
                    await self.paste(latest.url, to: destination, request: request, in: model)
                } else {
                    self.copy(latest.url, in: model)
                }
            }
        default:
            guard let path = ref.payload else { return }
            copy(URL(fileURLWithPath: path), in: model)
        }
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == nil ? nil : "Copy Image"
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == nil ? nil : "doc.on.doc"
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == nil ? nil : model.pasteTitle("Paste Image to")
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let path = ref.payload else { return }
        let destination = destination(model)
        let request = UUID()
        invocation = request
        Task { [weak self, weak model] in
            guard let self, let model else { return }
            await self.paste(URL(fileURLWithPath: path), to: destination, request: request, in: model)
        }
    }

    /// Copies the screenshot as image data (PNG) with its file URL.
    @discardableResult
    func copy(_ url: URL, in model: LauncherModel, announce: Bool = true) -> Bool {
        let name = url.lastPathComponent.truncatedForFeedback
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.feedback = .error("“\(name)” has moved or was deleted.")
            return false
        }
        guard let png = ScreenshotImageData.png(at: url) else {
            model.feedback = .error("“\(name)” couldn't be read as an image.")
            return false
        }
        guard model.clipboard.copyImage(pngData: png, fileURL: url) else {
            model.feedback = .error(model.clipboard.lastCopyError ?? "Couldn't write to the clipboard. Try again.")
            return false
        }
        if announce { model.toast("Copied “\(name)”") }
        return true
    }

    /// Copies the image, then pastes it into the destination captured when the command ran,
    /// only if that app is still where the person is. Otherwise the image stays copied, and
    /// the launcher says so.
    func paste(_ url: URL, to destination: PasteDestination?, request: UUID, in model: LauncherModel) async {
        guard invocation == request, copy(url, in: model, announce: false) else { return }
        let name = url.lastPathComponent.truncatedForFeedback
        guard canPasteAcrossApps(model) else {
            model.feedback = .info("Copied “\(name)” to the isolated verification pasteboard. Cross-app paste is disabled in this mode.")
            return
        }
        guard let destination else {
            model.toast("Copied “\(name)” to the clipboard. Press ⌘V to paste it.")
            return
        }
        let front = frontmostPID()
        guard front == destination.pid || front == ProcessInfo.processInfo.processIdentifier else {
            model.toast("Copied “\(name)” to the clipboard instead: \(destination.name) isn't in front anymore.")
            return
        }
        let changeCount = model.clipboard.changeCount
        model.panel?.dismiss(restoreFocus: false)
        do {
            try await pasteInto(destination, changeCount)
        } catch {
            model.panel?.show()
            model.feedback = .error("Copied “\(name)” to the clipboard, but couldn't paste into \(destination.name). \(error.localizedDescription)")
        }
    }

    // MARK: Scope

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.scope.id else { return [] }
        index.startWatchingIfNeeded()
        return index.matching(query).map(row)
    }

    func row(_ record: ScreenshotRecord) -> LauncherItem {
        LauncherItem(
            id: "screenshot.\(record.path)", title: record.name,
            subtitle: record.createdAt.formatted(date: .abbreviated, time: .shortened), symbol: "photo", kind: .file,
            badge: "Screenshot", iconURL: record.url,
            action: .provided(
                ProvidedRef(
                    provider: id, id: record.path, payload: record.path, arguments: ["version": record.version],
                    copyText: nil, primaryTitle: "Copy Image", traits: [])))
    }

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.scope.id else { return nil }
        let columns = model.screenshotSettings.columns
        let renderer = GridTileRenderer { item, selected in
            AnyView(ScreenshotTile(item: item, selected: selected, columns: columns))
        }
        let dates = Dictionary(index.records.map { ($0.path, $0.createdAt) }, uniquingKeysWith: { first, _ in first })
        let calendar = Calendar.current
        var days: [Date] = []
        var byDay: [Date: [LauncherItem]] = [:]
        for item in items {
            guard case .provided(let ref) = item.action, let path = ref.payload else { continue }
            let day = calendar.startOfDay(for: dates[path] ?? .distantPast)
            if byDay[day] == nil { days.append(day) }
            byDay[day, default: []].append(item)
        }
        return days.map { day in
            LauncherResultGroup(
                id: "screenshots.\(day.timeIntervalSinceReferenceDate)",
                title: LauncherModel.dayTitle(for: day, calendar: calendar), style: .grid, items: byDay[day] ?? [],
                columns: columns, tile: renderer)
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        guard scope.id == Self.scope.id else { return nil }
        if index.isScanning { return ProvidedEmptyState(title: "Finding screenshots…", detail: "This takes a moment the first time.") }
        let filter = ScreenshotFilter.parse(query)
        if filter.hasInvalidDate {
            return ProvidedEmptyState(
                title: "OpenRay can't read that date",
                detail: "Try date:today, date:yesterday, date:last week, date:Nov 3 or date:2026-11-26.", symbol: "calendar")
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let waiting = index.pendingRecognition > 0 ? " Text is still being read from \(index.pendingRecognition) images." : ""
            return ProvidedEmptyState(
                title: "No screenshots match “\(query.truncatedForFeedback)”",
                detail: "Search names and text, or narrow with text:, name: and date:.\(waiting)", symbol: "magnifyingglass")
        }
        return ProvidedEmptyState(
            title: "No screenshots yet",
            detail: "Screenshots saved to your screenshot folder or Desktop appear here. Add more folders in Settings › Screenshots.")
    }

    // MARK: Actions

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard let path = ref.payload else { return [] }
        let url = URL(fileURLWithPath: path)
        var entries = [
            ActionEntry(
                id: "quickLook", title: "Quick Look", symbol: "eye", shortcut: .command("Y"), key: "y", modifiers: .command,
                group: .item
            ) { [weak model] in
                // A verification run never opens a real screenshot.
                guard InertReadBoundary.allows(url) else {
                    model?.feedback = .info("Quick Look is off for files outside fixtures in this mode.")
                    return
                }
                model?.panel?.toggleQuickLook(url)
            },
            ActionEntry(
                id: "open", title: "Open", symbol: "arrow.up.forward.app", shortcut: .command("O"), key: "o",
                modifiers: .command, group: .item
            ) { [weak model, workspace] in
                guard let model else { return }
                model.openWithDefaultApp(url, workspace: workspace)
            },
            ActionEntry(
                id: "reveal", title: "Reveal in Finder", symbol: "folder", shortcut: .command("R", shift: true), key: "r",
                modifiers: [.command, .shift], group: .item
            ) { [weak model] in model?.revealInFinder(url) },
        ]
        // With text recognition off, recognized text is neither searched nor copied.
        if model.screenshotSettings.recognizesText, let text = index.records.first(where: { $0.path == path })?.text,
            !text.isEmpty
        {
            entries.append(
                ActionEntry(
                    id: "copyText", title: "Copy Text from Image", symbol: "text.viewfinder",
                    shortcut: .command("C", shift: true), key: "c", modifiers: [.command, .shift], group: .item
                ) { [weak model] in model?.copy(text, label: "text from \(url.lastPathComponent)") })
        }
        entries.append(
            ActionEntry(
                id: "copyPath", title: "Copy Path", symbol: "doc.on.doc", shortcut: KeyShortcut(["⌥", "⌘", "C"]),
                key: "c", modifiers: [.command, .option], group: .item
            ) { [weak model] in model?.copy(path, label: LauncherModel.shortenedPath(url)) })
        entries.append(
            ActionEntry(
                id: "trash", title: "Move to Trash", symbol: "trash", shortcut: KeyShortcut(["⌘", "⌫"]), key: .delete,
                modifiers: .command, group: .organize, isDestructive: true
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                model.askToTrash(url, workspace: self.workspace) { self.index.remove(path: path) }
            })
        let columns = model.screenshotSettings.columns
        if columns > ScreenshotSettings.columnRange.lowerBound {
            entries.append(
                ActionEntry(
                    id: "largerTiles", title: "Larger Tiles", symbol: "plus.magnifyingglass",
                    shortcut: .command("+"), key: "=", modifiers: .command, group: .panel
                ) { [weak model] in model?.setScreenshotColumns(columns - 1) })
        }
        if columns < ScreenshotSettings.columnRange.upperBound {
            entries.append(
                ActionEntry(
                    id: "smallerTiles", title: "Smaller Tiles", symbol: "minus.magnifyingglass",
                    shortcut: .command("-"), key: "-", modifiers: .command, group: .panel
                ) { [weak model] in model?.setScreenshotColumns(columns + 1) })
        }
        if columns != ScreenshotSettings.defaultColumns {
            entries.append(
                ActionEntry(
                    id: "defaultTiles", title: "Default Tile Size", symbol: "square.grid.2x2", shortcut: .command("0"),
                    key: "0", modifiers: .command, group: .panel
                ) { [weak model] in model?.setScreenshotColumns(ScreenshotSettings.defaultColumns) })
        }
        entries.append(
            ActionEntry(
                id: "refreshIndex", title: "Refresh Screenshots", symbol: "arrow.clockwise", shortcut: .command("R"),
                key: "r", modifiers: .command, group: .panel
            ) { [weak self] in
                guard let self else { return }
                Task { await self.index.refresh() }
            })
        return entries
    }

    func itemNoun(for ref: ProvidedRef) -> String { "Screenshot" }
}

/// A screenshot's tile: a thumbnail, loaded off the main thread, over its name.
struct ScreenshotTile: View {
    let item: LauncherItem
    var selected: Bool
    var columns: Int
    @State private var image: NSImage?

    private var height: CGFloat { columns <= 3 ? 150 : columns == 4 ? 110 : columns == 5 ? 88 : 72 }

    /// The indexed file's version, so a replaced screenshot loads its new picture.
    private var version: String {
        if case .provided(let ref) = item.action { return ref.arguments["version"] ?? "" }
        return ""
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OR.Color.fill1)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(OR.Color.text3)
                }
            }
            .frame(height: height)
            Text(item.title).font(OR.Font.callout).foregroundStyle(selected ? OR.Color.text : OR.Color.text2)
                .lineLimit(1).truncationMode(.middle)
        }
        .task(id: "\(item.iconURL?.path ?? "")#\(version)") {
            guard let url = item.iconURL else { return }
            image = ScreenshotThumbnails.shared.cached(url, version: version)
            if image == nil { image = await ScreenshotThumbnails.shared.thumbnail(for: url, version: version) }
        }
    }
}
