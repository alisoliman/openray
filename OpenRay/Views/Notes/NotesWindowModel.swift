import AppKit
import Foundation
import Observation

/// Back and forward through the notes opened in the Notes window, like a browser's history.
struct NoteHistory: Equatable, Sendable {
    private(set) var back: [UUID] = []
    private(set) var forward: [UUID] = []
    static let limit = 50

    /// Opening `next` from `current` records `current` and clears forward history.
    mutating func visit(_ next: UUID, from current: UUID?) {
        guard let current, current != next else { return }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward = []
    }

    /// The previous note that still exists. Skipped entries are dropped.
    mutating func goBack(from current: UUID?, isAvailable: (UUID) -> Bool) -> UUID? {
        while let candidate = back.popLast() {
            guard isAvailable(candidate), candidate != current else { continue }
            if let current { forward.append(current) }
            return candidate
        }
        return nil
    }

    /// The next note that still exists. Skipped entries are dropped.
    mutating func goForward(from current: UUID?, isAvailable: (UUID) -> Bool) -> UUID? {
        while let candidate = forward.popLast() {
            guard isAvailable(candidate), candidate != current else { continue }
            if let current { back.append(current) }
            return candidate
        }
        return nil
    }

    mutating func remove(_ id: UUID) {
        back.removeAll { $0 == id }
        forward.removeAll { $0 == id }
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
}

/// A short message in the Notes window's footer.
struct NotesNotice: Equatable, Identifiable {
    enum Tone: Equatable { case success, info, warning, error }
    let id = UUID()
    var tone: Tone
    var text: String

    static func success(_ text: String) -> NotesNotice { NotesNotice(tone: .success, text: text) }
    static func info(_ text: String) -> NotesNotice { NotesNotice(tone: .info, text: text) }
    static func warning(_ text: String) -> NotesNotice { NotesNotice(tone: .warning, text: text) }
    static func error(_ text: String) -> NotesNotice { NotesNotice(tone: .error, text: text) }
}

/// ⌘P: search notes, or Recently Deleted.
struct NotesBrowserState: Equatable {
    var query = ""
    var showsDeleted = false
    var selection: UUID?
}

/// The `/` menu while it's open: where the slash is, what follows it, and the highlighted entry.
struct NoteSlashMenu: Equatable {
    var slash: Int
    var query: String
    var selection = 0
    /// The caret's rectangle in the editor's coordinates, flipped (origin top left).
    var anchor: CGRect = .zero

    var matches: [NoteSlashCommand] { NoteSlashCommand.matching(query) }
}

/// The window that shows a note. The live one is `NotesWindowController`; tests use a fake.
@MainActor
protocol NotesWindowPresenting: AnyObject {
    var isVisible: Bool { get }
    /// Visible and taking keystrokes. A toggle hides a window that has focus and brings
    /// forward one that's behind other apps.
    var isKey: Bool { get }
    /// Shows the window and makes it key. False when this launch doesn't allow windows.
    @discardableResult func show() -> Bool
    func hide()
}

/// Where an export goes. The live one asks with a save panel.
extension NotesWindowPresenting {
    var isKey: Bool { isVisible }
}

@MainActor
protocol NoteExportDestination: AnyObject {
    /// The file to write, or nil when the person cancelled or this launch can't ask.
    func chooseURL(suggestedName: String, format: NoteExportFormat) async -> URL?
}

/// An image file chosen for `/` › Image. The live one asks with an open panel.
@MainActor
protocol NoteImagePicking: AnyObject {
    func chooseImage() async -> URL?
}

/// The state of the floating Notes window: which note is open, its text as you type, history,
/// pins, Recently Deleted and export. It writes through `LibraryStore` and never touches
/// AppKit itself; the window, panels and clock are injected.
@MainActor
@Observable
final class NotesWindowModel {
    let store: LibraryStore
    let assets: NoteAssetStore
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored weak var presenter: (any NotesWindowPresenting)?
    @ObservationIgnored var exportDestination: any NoteExportDestination
    @ObservationIgnored var imagePicker: any NoteImagePicking
    /// How long typing pauses before the note saves.
    @ObservationIgnored var autosaveDelay: Duration = .milliseconds(600)

    /// The open note. With a `draft`, it's the draft's id, which isn't in the library yet.
    private(set) var currentID: UUID?
    /// A new note that has no text yet. It's saved once it has some, and dropped if left empty.
    private(set) var draft: QuickNote?
    /// The open note's text, as the editor shows it.
    private(set) var text = ""
    /// Bumped when the model replaces `text` (another note opened), so the editor reloads.
    private(set) var textRevision = 0
    private(set) var history = NoteHistory()
    /// Typed text not saved yet.
    private(set) var hasUnsavedText = false
    var browser: NotesBrowserState?
    var notice: NotesNotice?
    var slashMenu: NoteSlashMenu?
    /// Asked before Empty Recently Deleted; ↩ confirms.
    var confirmsEmptyingDeleted = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// A click in the `/` menu. The editor sets it, since it owns the text view.
    @ObservationIgnored var onPickSlashCommand: ((NoteSlashCommand) -> Void)?

    init(
        store: LibraryStore, assets: NoteAssetStore, now: @escaping () -> Date = { .now },
        exportDestination: any NoteExportDestination = SavePanelNoteExport(),
        imagePicker: any NoteImagePicking = OpenPanelImagePicker()
    ) {
        self.store = store
        self.assets = assets
        self.now = now
        self.exportDestination = exportDestination
        self.imagePicker = imagePicker
    }

    // MARK: Reading

    var notes: [QuickNote] { store.database.notes }
    var orderedNotes: [QuickNote] { NoteCollection.ordered(notes) }
    var pinnedNotes: [QuickNote] { NoteCollection.pinned(notes) }
    var deletedNotes: [QuickNote] { NoteCollection.deleted(notes) }

    /// The open note as saved, or the draft.
    var currentNote: QuickNote? {
        if let draft { return draft }
        guard let currentID else { return nil }
        return notes.first { $0.id == currentID }
    }

    var isDraft: Bool { draft != nil }
    var isWindowVisible: Bool { presenter?.isVisible ?? false }
    var isWindowKey: Bool { presenter?.isKey ?? false }

    /// What the window shows as the title: the note's title, or the first line as you type it.
    var displayTitle: String {
        if let note = currentNote, !note.titleFollowsContent { return note.title }
        let title = QuickNote.markdownTitle(from: text)
        return title.isEmpty ? "New Note" : title
    }

    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }

    /// The ⌘-digit that opens the open note, when it's pinned.
    var currentPinDigit: Int? { currentNote?.pinnedIndex.flatMap(NoteCollection.digit(forPinSlot:)) }

    /// ⌘P's rows: notes or Recently Deleted, filtered by the browser's query.
    var browserResults: [QuickNote] {
        guard let browser else { return [] }
        let source = browser.showsDeleted ? deletedNotes : orderedNotes
        let query = browser.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.compactMap { note -> (QuickNote, Int)? in
            if let score = SearchMatcher.score(query, in: note.title) { return (note, score + 100) }
            if note.content.localizedCaseInsensitiveContains(query) { return (note, 0) }
            return nil
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func exists(_ id: UUID) -> Bool { notes.contains { $0.id == id && !$0.isDeleted } }

    // MARK: Window

    /// Shows the window with `noteID`, or the note that was open, or the most recent one.
    @discardableResult
    func show(noteID: UUID? = nil) -> Bool {
        purgeExpired()
        if let noteID {
            open(noteID)
        } else {
            reloadIfChangedElsewhere()
            if currentNote == nil || currentNote?.isDeleted == true {
                if let first = orderedNotes.first { load(first) } else { startDraft() }
            }
        }
        return presenter?.show() ?? false
    }

    /// Shows a new, empty note.
    @discardableResult
    func showNewNote(content: String = "") -> Bool {
        purgeExpired()
        newNote()
        if !content.isEmpty { edit(content) }
        return presenter?.show() ?? false
    }

    /// Hides the window when it has focus; otherwise shows it, bringing it forward.
    func toggle() {
        if isWindowKey { hide() } else { show() }
    }

    func hide() {
        closeOverlays()
        leaveCurrentIfEmpty()
        flush()
        presenter?.hide()
    }

    func closeOverlays() {
        browser = nil
        slashMenu = nil
        confirmsEmptyingDeleted = false
    }

    // MARK: Navigation

    /// Opens a note, recording the one that was open in history.
    func open(_ id: UUID) {
        guard id != currentID || draft != nil else { return }
        guard let note = notes.first(where: { $0.id == id }) else {
            notice = .warning("This note no longer exists.")
            return
        }
        guard !note.isDeleted else {
            notice = .info("“\(note.title.truncatedForFeedback)” is in Recently Deleted. Restore it to edit it.")
            return
        }
        let previous = currentID
        leaveCurrentIfEmpty()
        flush()
        history.visit(id, from: previous)
        load(note)
    }

    /// ⌘N: a new note. A note left empty is dropped, not saved.
    func newNote() {
        if draft != nil, text.isEmpty { return }
        let previous = currentID
        leaveCurrentIfEmpty()
        flush()
        startDraft()
        if let previous, let currentID { history.visit(currentID, from: previous) }
    }

    /// ⌘[: the note opened before this one.
    func goBack() {
        leaveCurrentIfEmpty()
        flush()
        guard let id = history.goBack(from: currentID, isAvailable: exists), let note = notes.first(where: { $0.id == id })
        else { return }
        load(note)
    }

    /// ⌘]: the note opened after this one.
    func goForward() {
        leaveCurrentIfEmpty()
        flush()
        guard let id = history.goForward(from: currentID, isAvailable: exists), let note = notes.first(where: { $0.id == id })
        else { return }
        load(note)
    }

    /// ⌘1 … ⌘9, ⌘0.
    func openPinned(digit: Int) {
        guard let slot = NoteCollection.pinSlot(forDigit: digit) else { return }
        let pinned = pinnedNotes
        guard pinned.indices.contains(slot) else {
            notice = .info("No note is pinned to ⌘\(digit). Pin one with ⇧⌘P.")
            return
        }
        open(pinned[slot].id)
    }

    private func load(_ note: QuickNote) {
        draft = nil
        currentID = note.id
        text = note.content
        hasUnsavedText = false
        slashMenu = nil
        textRevision += 1
    }

    private func startDraft() {
        let note = QuickNote(title: "", content: "", modifiedAt: now(), formatVersion: QuickNote.markdownFormat)
        draft = note
        currentID = note.id
        text = ""
        hasUnsavedText = false
        slashMenu = nil
        textRevision += 1
    }

    /// The library changed outside the window (the inline editor saved, or the launcher deleted
    /// the note). Shows the saved text when nothing is waiting to save.
    func reloadIfChangedElsewhere() {
        guard draft == nil, !hasUnsavedText, let currentID else { return }
        guard let note = notes.first(where: { $0.id == currentID }), !note.isDeleted else {
            self.currentID = nil
            return
        }
        if note.content != text {
            text = note.content
            textRevision += 1
        }
    }

    // MARK: Editing and saving

    /// The editor's text changed. It saves after a short pause.
    func edit(_ newText: String) {
        guard newText != text || hasUnsavedText else { return }
        text = newText
        hasUnsavedText = true
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves typed text now. False, with a notice, when it couldn't be saved.
    @discardableResult
    func flush() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasUnsavedText else { return true }
        let content = text
        let blank = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard content.count <= QuickNote.maximumLength else {
            notice = .error("Notes support up to 100,000 characters.")
            return false
        }
        if var note = draft {
            // A new note is saved once it has words.
            guard !blank else { return true }
            note.content = content
            note.title = Self.title(for: content)
            note.modifiedAt = now()
            note.formatVersion = QuickNote.markdownFormat
            guard store.update({ $0.notes.insert(note, at: 0) }) else {
                notice = .error(store.errorMessage ?? "This note couldn't be saved.")
                return false
            }
            draft = nil
            currentID = note.id
        } else if let id = currentID, let note = notes.first(where: { $0.id == id }) {
            // An emptied note keeps its last words until you leave it, then it's removed.
            guard !blank else { return true }
            guard note.content != content else {
                hasUnsavedText = false
                return true
            }
            var updated = note
            if note.titleFollowsContent { updated.title = Self.title(for: content) }
            updated.content = content
            updated.modifiedAt = now()
            updated.formatVersion = QuickNote.markdownFormat
            let saved = store.update { database in
                guard let index = database.notes.firstIndex(where: { $0.id == id }) else { return }
                database.notes[index] = updated
            }
            guard saved else {
                notice = .error(store.errorMessage ?? "This note couldn't be saved.")
                return false
            }
        } else {
            // The note was deleted elsewhere while it was open: keep the words as a new note.
            guard !blank else { return true }
            let note = QuickNote(
                title: Self.title(for: content), content: content, modifiedAt: now(), formatVersion: QuickNote.markdownFormat)
            guard store.update({ $0.notes.insert(note, at: 0) }) else {
                notice = .error(store.errorMessage ?? "This note couldn't be saved.")
                return false
            }
            currentID = note.id
        }
        hasUnsavedText = false
        return true
    }

    static func title(for content: String) -> String {
        let title = QuickNote.markdownTitle(from: content)
        return title.isEmpty ? "Untitled Note" : title
    }

    /// Leaving a note you emptied removes it, as the inline editor does; a new empty note is dropped.
    private func leaveCurrentIfEmpty() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if draft != nil {
            draft = nil
            if let currentID { history.remove(currentID) }
            currentID = nil
            hasUnsavedText = false
            return
        }
        guard let id = currentID, notes.contains(where: { $0.id == id }) else { return }
        autosaveTask?.cancel()
        let removed = store.update { database in
            database.notes.removeAll { $0.id == id }
            database.favoriteIDs.remove("note.\(id)")
            database.usage.removeAll { $0.id == "note.\(id)" }
            NoteCollection.normalizePins(&database.notes)
        }
        if removed {
            history.remove(id)
            currentID = nil
            hasUnsavedText = false
        }
    }

    /// Applies an edit the editor computed (a task toggle, a format command), as if typed.
    func apply(_ edit: NoteMarkdown.Edit) {
        self.edit(edit.applied(to: text))
    }

    // MARK: Pins

    /// ⇧⌘P.
    func togglePin() {
        if draft != nil {
            guard flush(), draft == nil else {
                notice = .info("Write something before pinning this note.")
                return
            }
        }
        guard let id = currentID else { return }
        var pinned = false
        var failure: Error?
        let saved = store.update { database in
            do { pinned = try NoteCollection.togglePin(id, in: &database.notes) } catch {
                failure = error
                throw error
            }
        }
        if let failure {
            notice = .warning(failure.localizedDescription)
        } else if saved {
            let digit = currentPinDigit.map { " · ⌘\($0)" } ?? ""
            notice = .success(pinned ? "Pinned\(digit)" : "Unpinned")
        } else {
            notice = .error(store.errorMessage ?? "The pin couldn't be saved.")
        }
    }

    func movePin(_ id: UUID, by offset: Int) {
        store.update { NoteCollection.movePin(id, by: offset, in: &$0.notes) }
    }

    // MARK: Recently Deleted

    /// Moves the open note to Recently Deleted and opens the next one.
    func deleteCurrentNote() {
        if draft != nil {
            draft = nil
            text = ""
            hasUnsavedText = false
            openFallbackNote()
            return
        }
        guard let id = currentID, let note = notes.first(where: { $0.id == id }) else { return }
        flush()
        let moved = store.update { database in
            NoteCollection.moveToRecentlyDeleted(id, at: self.now(), in: &database.notes)
        }
        guard moved else {
            notice = .error(store.errorMessage ?? "This note couldn't be deleted.")
            return
        }
        history.remove(id)
        currentID = nil
        openFallbackNote()
        notice = .success("Moved “\(note.title.truncatedForFeedback)” to Recently Deleted")
    }

    private func openFallbackNote() {
        if let previous = history.goBack(from: nil, isAvailable: exists), let note = notes.first(where: { $0.id == previous }) {
            load(note)
        } else if let first = orderedNotes.first {
            load(first)
        } else {
            startDraft()
        }
    }

    /// Brings a note back and opens it.
    func restore(_ id: UUID) {
        guard store.update({ NoteCollection.restore(id, at: self.now(), in: &$0.notes) }) else {
            notice = .error(store.errorMessage ?? "This note couldn't be restored.")
            return
        }
        if browser?.showsDeleted == true { browser = nil }
        open(id)
        notice = .success("Restored")
    }

    /// Removes a note from Recently Deleted for good, with any images only it used.
    func deletePermanently(_ id: UUID) {
        let removed = store.update { database in
            database.notes.removeAll { $0.id == id && $0.isDeleted }
            database.favoriteIDs.remove("note.\(id)")
            database.usage.removeAll { $0.id == "note.\(id)" }
        }
        guard removed else {
            notice = .error(store.errorMessage ?? "This note couldn't be deleted.")
            return
        }
        assets.removeUnreferenced(keeping: notes)
    }

    /// Empties Recently Deleted. Asks first, through `confirmsEmptyingDeleted`.
    func emptyRecentlyDeleted() {
        confirmsEmptyingDeleted = false
        let ids = Set(deletedNotes.map { "note.\($0.id)" })
        guard !ids.isEmpty else { return }
        let removed = store.update { database in
            database.notes.removeAll(where: \.isDeleted)
            database.favoriteIDs.subtract(ids)
            database.usage.removeAll { ids.contains($0.id) }
        }
        guard removed else {
            notice = .error(store.errorMessage ?? "Recently Deleted couldn't be emptied.")
            return
        }
        assets.removeUnreferenced(keeping: notes)
        notice = .success("Recently Deleted is empty")
    }

    /// Removes notes deleted 60 or more days ago. Runs whenever the window opens.
    @discardableResult
    func purgeExpired() -> Int {
        let expired = NoteCollection.expired(notes, now: now())
        guard !expired.isEmpty, !store.isReadOnly else { return 0 }
        let ids = Set(expired.map(\.id))
        let itemIDs = Set(ids.map { "note.\($0)" })
        let removed = store.update { database in
            database.notes.removeAll { ids.contains($0.id) }
            database.favoriteIDs.subtract(itemIDs)
            database.usage.removeAll { itemIDs.contains($0.id) }
        }
        guard removed else { return 0 }
        assets.removeUnreferenced(keeping: notes)
        return expired.count
    }

    // MARK: Browser

    /// ⌘P opens or closes the browser.
    func toggleBrowser() {
        if browser == nil {
            flush()
            slashMenu = nil
            browser = NotesBrowserState(selection: currentNote?.isDeleted == false ? currentID : nil)
            // Read before writing: `browser?.x = …` keeps `browser` open while the right side runs.
            let first = browserResults.first?.id
            if browser?.selection == nil { browser?.selection = first }
        } else {
            browser = nil
        }
    }

    func setBrowserShowsDeleted(_ showsDeleted: Bool) {
        guard browser != nil else { return }
        browser?.showsDeleted = showsDeleted
        let first = browserResults.first?.id
        browser?.selection = first
        confirmsEmptyingDeleted = false
    }

    func setBrowserQuery(_ query: String) {
        guard browser != nil else { return }
        browser?.query = query
        let first = browserResults.first?.id
        browser?.selection = first
    }

    /// ↑/↓ in the browser.
    func moveBrowserSelection(by offset: Int) {
        let results = browserResults
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == browser?.selection } ?? -1
        let next = min(max(index + offset, 0), results.count - 1)
        browser?.selection = results[next].id
    }

    /// ↩ in the browser: open the note, or restore it from Recently Deleted.
    func openBrowserSelection() {
        guard let browser, let id = browser.selection ?? browserResults.first?.id else { return }
        if browser.showsDeleted {
            restore(id)
        } else {
            self.browser = nil
            open(id)
        }
    }

    // MARK: Export and images

    /// Exports the open note through a save panel.
    func export(_ format: NoteExportFormat) async {
        guard flush(), let note = currentNote, draft == nil else {
            notice = .info("Write something before exporting this note.")
            return
        }
        let name = NoteExporter.suggestedFileName(for: note, format: format)
        guard let url = await exportDestination.chooseURL(suggestedName: name, format: format) else { return }
        let output = NoteExporter.export(note, as: format, assets: assets)
        do {
            try Data(output.utf8).write(to: url, options: [.atomic])
            notice = .success("Exported “\(url.lastPathComponent.truncatedForFeedback)”")
        } catch {
            notice = .error("The note couldn't be exported. \(error.localizedDescription)")
        }
    }

    /// Stores pasted or dropped image data and returns the reference to insert, or nil with a notice.
    func storeImage(_ data: Data, fileExtension: String) -> String? {
        do {
            return try assets.save(data, fileExtension: fileExtension)
        } catch {
            notice = .error(error.localizedDescription)
            return nil
        }
    }

    /// `/` › Image: asks for a file and stores it.
    func pickImage() async -> String? {
        guard let url = await imagePicker.chooseImage() else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            notice = .error("OpenRay couldn't read “\(url.lastPathComponent)”.")
            return nil
        }
        return storeImage(data, fileExtension: url.pathExtension)
    }
}

// MARK: - Live panels

/// The save panel for exports. It's a live window, so it's refused in tests and verification mode.
@MainActor
final class SavePanelNoteExport: NoteExportDestination {
    let guardrail: SideEffectGuard

    init(guardrail: SideEffectGuard = .current) {
        self.guardrail = guardrail
    }

    func chooseURL(suggestedName: String, format: NoteExportFormat) async -> URL? {
        guard (try? guardrail.check("showing a save panel")) != nil else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.title = "Export Note as \(format.title)"
        NSApp.activate()
        return await panel.begin() == .OK ? panel.url : nil
    }
}

/// The open panel for `/` › Image. Refused in tests and verification mode.
@MainActor
final class OpenPanelImagePicker: NoteImagePicking {
    let guardrail: SideEffectGuard

    init(guardrail: SideEffectGuard = .current) {
        self.guardrail = guardrail
    }

    func chooseImage() async -> URL? {
        guard (try? guardrail.check("showing an open panel")) != nil else { return nil }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Add Image to Note"
        NSApp.activate()
        return await panel.begin() == .OK ? panel.url : nil
    }
}
