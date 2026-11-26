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

    var id: String { Self.registration.id }
    let index: ScreenshotIndex
    let workspace: any FileWorkspace

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
            Task {
                index.startWatchingIfNeeded()
                await index.refresh()
                guard let latest = index.latest else {
                    model.feedback = .info("No screenshots yet. Take one with ⇧⌘3 or ⇧⌘4.")
                    return
                }
                model.store.recordUse(of: item.id)
                if pastes { model.paste(Self.fileItem(latest.url)) } else { copy(latest.url, in: model) }
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
        model.paste(Self.fileItem(URL(fileURLWithPath: path)))
    }

    /// Copies the screenshot as a file, which apps paste as the image.
    func copy(_ url: URL, in model: LauncherModel) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            model.feedback = .error("“\(url.lastPathComponent)” has moved or was deleted.")
            return
        }
        if model.clipboard.copy(ClipboardEntry(content: .files([url]), sourceName: "OpenRay")) {
            model.toast("Copied “\(url.lastPathComponent.truncatedForFeedback)”")
        } else {
            model.feedback = .error(model.clipboard.lastCopyError ?? "Couldn't write to the clipboard. Try again.")
        }
    }

    /// The launcher's own file row, so ⌘↩ pastes through the shared file-paste path.
    static func fileItem(_ url: URL) -> LauncherItem {
        LauncherItem(
            id: "file.\(url.path)", title: url.lastPathComponent, subtitle: "", symbol: "photo", kind: .file,
            badge: "Image", iconURL: url, action: .file(url))
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
            badge: "Screenshot", keywords: record.text ?? "", iconURL: record.url,
            action: .provided(
                ProvidedRef(
                    provider: id, id: record.path, payload: record.path, copyText: nil, primaryTitle: "Copy Image",
                    traits: [])))
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
                detail: "Try date:today, date:yesterday, date:last week or date:2026-11-26.", symbol: "calendar")
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
            ) { [weak model] in model?.panel?.toggleQuickLook(url) },
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
        if let text = index.records.first(where: { $0.path == path })?.text, !text.isEmpty {
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
        .task(id: item.iconURL) {
            guard let url = item.iconURL else { return }
            image = ScreenshotThumbnails.shared.cached(url)
            if image == nil { image = await ScreenshotThumbnails.shared.thumbnail(for: url) }
        }
    }
}
