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
    /// The last save failed: the words stay here, and the note stays open, until a save works
    /// or the person discards them.
    private(set) var saveFailed = false
    /// The saved words the buffer started from, to notice when another editor changed the note.
    @ObservationIgnored private(set) var baseContent: String?
    var browser: NotesBrowserState?
    var notice: NotesNotice?
    var slashMenu: NoteSlashMenu?
    /// Asked before Empty Recently Deleted; ↩ confirms.
    var confirmsEmptyingDeleted = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// A click in the `/` menu. The editor sets it, since it owns the text view.
    @ObservationIgnored var onPickSlashCommand: ((NoteSlashCommand) -> Void)?
    /// A note was saved here, so another editor showing it can refresh. Set by `NotesCenter`.
    @ObservationIgnored var onSaved: ((UUID) -> Void)?
    /// Note text open in other editors (the launcher's inline editor), whose images a purge keeps.
    @ObservationIgnored var externalTexts: () -> [String] = { [] }
    /// False keeps an inert launch (tests, verification) from purging an on-disk library.
    @ObservationIgnored var mayPurgeLibraryOnDisk = !SideEffectGuard.isInert
    /// Every image the editor's Undo history can bring back since this note opened. A purge keeps
    /// these files until another note opens and that history is gone.
    @ObservationIgnored private var undoReachableImages = Set<String>()
    /// Set once the person has been told about recovered text this launch.
    @ObservationIgnored private var didAnnounceRecovery = false

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
    /// Recently Deleted, without notes past their 60 days, even before a purge removes them.
    var deletedNotes: [QuickNote] {
        let expired = Set(NoteCollection.expired(notes, now: now()).map(\.id))
        return NoteCollection.deleted(notes).filter { !expired.contains($0.id) }
    }

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
                if hasUnsavedText {
                    // The note went away elsewhere while its words waited to save. They become a
                    // note of their own, or stay here with the save error; never replaced.
                    flush()
                } else if let first = orderedNotes.first {
                    load(first)
                } else {
                    startDraft()
                }
            }
        }
        announceRecoveredText()
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

    /// Hides the window. When the open note's words can't be saved, it stays open to say so.
    func hide() {
        closeOverlays()
        guard leaveCurrent() else { return }
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
        if id == currentID, draft == nil {
            reloadIfChangedElsewhere()
            return
        }
        guard let note = notes.first(where: { $0.id == id }) else {
            notice = .warning("This note no longer exists.")
            return
        }
        guard !note.isDeleted else {
            notice = .info("“\(note.title.truncatedForFeedback)” is in Recently Deleted. Restore it to edit it.")
            return
        }
        let previous = currentID
        guard leaveCurrent() else { return }
        history.visit(id, from: previous)
        load(note)
    }

    /// ⌘N: a new note. A note left empty is dropped, not saved.
    func newNote() {
        if draft != nil, isBlank(text) { return }
        let previous = currentID
        guard leaveCurrent() else { return }
        startDraft()
        if let previous, let currentID { history.visit(currentID, from: previous) }
    }

    /// ⌘[: the note opened before this one.
    func goBack() {
        guard leaveCurrent() else { return }
        guard let id = history.goBack(from: currentID, isAvailable: exists), let note = notes.first(where: { $0.id == id })
        else { return }
        load(note)
    }

    /// ⌘]: the note opened after this one.
    func goForward() {
        guard leaveCurrent() else { return }
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
        baseContent = note.content
        hasUnsavedText = false
        saveFailed = false
        resetUndoReachableImages()
        slashMenu = nil
        textRevision += 1
    }

    private func startDraft() {
        let note = QuickNote(title: "", content: "", modifiedAt: now(), formatVersion: QuickNote.markdownFormat)
        draft = note
        currentID = note.id
        text = ""
        baseContent = nil
        hasUnsavedText = false
        saveFailed = false
        resetUndoReachableImages()
        slashMenu = nil
        textRevision += 1
    }

    /// The library changed outside the window (the inline editor saved, or the launcher deleted
    /// the note). Shows the saved text when nothing is waiting to save.
    func reloadIfChangedElsewhere() {
        guard draft == nil, !hasUnsavedText, let currentID else { return }
        guard let note = notes.first(where: { $0.id == currentID }), !note.isDeleted else {
            // Deleted elsewhere: show the next note rather than words that no longer exist.
            history.remove(currentID)
            self.currentID = nil
            openFallbackNote()
            return
        }
        baseContent = note.content
        if note.content != text {
            text = note.content
            textRevision += 1
        }
    }

    private func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Editing and saving

    /// The editor's text changed. It saves after a short pause.
    func edit(_ newText: String) {
        guard newText != text || hasUnsavedText else { return }
        text = newText
        if newText.contains(NoteAssetStore.folderName + "/") {
            undoReachableImages.formUnion(NoteAssetStore.referencedNames(inTexts: [newText]))
        }
        hasUnsavedText = true
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Saves typed text now. False, with a notice, when it couldn't be saved; the words stay in
    /// the buffer, and the note stays open.
    @discardableResult
    func flush() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard hasUnsavedText else { return true }
        let content = text
        let blank = isBlank(content)
        guard content.count <= QuickNote.maximumLength else {
            return failSave("Notes support up to 100,000 characters. Shorten this note to save it.")
        }
        if var note = draft {
            // A new note is saved once it has words.
            guard !blank else { return true }
            note.content = content
            note.title = Self.title(for: content)
            note.modifiedAt = now()
            note.formatVersion = QuickNote.markdownFormat
            guard store.update({ $0.notes.insert(note, at: 0) }) else { return failSave(nil) }
            draft = nil
            currentID = note.id
        } else if let id = currentID, let note = notes.first(where: { $0.id == id }), !note.isDeleted {
            // A note whose title follows its words keeps its last words while it's empty; leaving
            // it moves it to Recently Deleted. A note with a title of its own can be empty.
            guard !blank || !note.titleFollowsContent else { return true }
            guard note.content != content else {
                finishSave(content)
                return true
            }
            if let base = baseContent, note.content != base {
                // Another editor changed this note since the window loaded it. Neither version
                // overwrites the other: these words become a note of their own.
                return saveAsNewNote(content, replacing: note)
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
            guard saved else { return failSave(nil) }
        } else {
            // The note was deleted elsewhere while it was open: keep the words as a new note.
            guard !blank else { return true }
            let note = QuickNote(
                title: Self.title(for: content), content: content, modifiedAt: now(), formatVersion: QuickNote.markdownFormat)
            guard store.update({ $0.notes.insert(note, at: 0) }) else { return failSave(nil) }
            if let currentID { history.remove(currentID) }
            currentID = note.id
        }
        finishSave(content)
        return true
    }

    private func finishSave(_ content: String) {
        baseContent = content
        hasUnsavedText = false
        saveFailed = false
        if let currentID { onSaved?(currentID) }
    }

    private func failSave(_ message: String?) -> Bool {
        saveFailed = true
        notice = .error(message ?? store.errorMessage ?? "This note couldn't be saved.")
        return false
    }

    private func saveAsNewNote(_ content: String, replacing original: QuickNote) -> Bool {
        let copy = QuickNote(
            title: Self.title(for: content), content: content, modifiedAt: now(), formatVersion: QuickNote.markdownFormat)
        guard store.update({ $0.notes.insert(copy, at: 0) }) else { return failSave(nil) }
        history.visit(copy.id, from: original.id)
        currentID = copy.id
        finishSave(content)
        notice = .warning("“\(original.title.truncatedForFeedback)” changed in another editor, so these edits are a new note.")
        return true
    }

    /// Drops typed words that couldn't be saved and shows the note as saved.
    func discardUnsavedChanges() {
        autosaveTask?.cancel()
        autosaveTask = nil
        if draft != nil {
            text = ""
            hasUnsavedText = false
            saveFailed = false
            textRevision += 1
        } else if let id = currentID, let note = notes.first(where: { $0.id == id }), !note.isDeleted {
            load(note)
        } else {
            // Its note was deleted or purged meanwhile: show another one.
            hasUnsavedText = false
            saveFailed = false
            if let currentID { history.remove(currentID) }
            currentID = nil
            openFallbackNote()
        }
        notice = .info("Changes discarded")
    }

    static func title(for content: String) -> String {
        let title = QuickNote.markdownTitle(from: content)
        return title.isEmpty ? "Untitled Note" : title
    }

    /// Settles the open note before another opens or the window hides. False keeps it open:
    /// its words couldn't be saved, and a notice says why.
    private func leaveCurrent() -> Bool {
        guard isBlank(text) else { return flush() }
        autosaveTask?.cancel()
        autosaveTask = nil
        if draft != nil {
            // A new note left empty was never saved, so there's nothing to keep.
            draft = nil
            if let currentID { history.remove(currentID) }
            currentID = nil
            hasUnsavedText = false
            saveFailed = false
            return true
        }
        guard let id = currentID, let note = notes.first(where: { $0.id == id }), !note.isDeleted else {
            hasUnsavedText = false
            return true
        }
        // A title-only note (OpenRay 0.1 saved those) stays as it is; so does one you emptied
        // that has a title of its own.
        guard note.titleFollowsContent, hasUnsavedText else { return flush() }
        // Another editor saved newer words since this buffer loaded: those stay, and the empty
        // buffer here is let go rather than trashing them.
        guard note.content == baseContent else {
            hasUnsavedText = false
            saveFailed = false
            return true
        }
        // Emptied: nothing is left of it, so it moves to Recently Deleted with its last saved words.
        let moved = store.update { NoteCollection.moveToRecentlyDeleted(id, at: self.now(), in: &$0.notes) }
        guard moved else { return failSave(store.errorMessage ?? "This note couldn't be moved to Recently Deleted.") }
        history.remove(id)
        currentID = nil
        hasUnsavedText = false
        saveFailed = false
        notice = .info("Moved the emptied note “\(note.title.truncatedForFeedback)” to Recently Deleted")
        return true
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
        if draft != nil, isBlank(text) {
            draft = nil
            text = ""
            hasUnsavedText = false
            saveFailed = false
            openFallbackNote()
            return
        }
        // Words that can't be saved aren't thrown away by deleting: the save error shows instead.
        // A new note with words is saved first, so it goes to Recently Deleted like any other.
        guard flush() else { return }
        // Read after saving: a conflict can have moved these words to a new note, and that's the
        // one on screen, so it's the one deleted, never the other editor's.
        guard draft == nil, let id = currentID, let note = notes.first(where: { $0.id == id }), !note.isDeleted else { return }
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

    /// Brings a note back and opens it. False, with a notice, when it couldn't be restored,
    /// including a note past its 60 days.
    @discardableResult
    func restore(_ id: UUID) -> Bool {
        if let note = notes.first(where: { $0.id == id }), NoteCollection.expired([note], now: now()).count == 1 {
            purgeExpired()
            notice = .warning("“\(note.title.truncatedForFeedback)” was in Recently Deleted for 60 days and is gone.")
            return false
        }
        guard notes.contains(where: { $0.id == id && $0.isDeleted }),
            store.update({ NoteCollection.restore(id, at: self.now(), in: &$0.notes) })
        else {
            notice = .error(store.errorMessage ?? "This note couldn't be restored.")
            return false
        }
        if browser?.showsDeleted == true { browser = nil }
        open(id)
        if currentID == id { notice = .success("Restored") }
        return true
    }

    /// Removes a note from Recently Deleted for good, with any images only it used.
    @discardableResult
    func deletePermanently(_ id: UUID) -> Bool {
        removeForGood(notes.filter { $0.id == id && $0.isDeleted }, failure: "This note couldn't be deleted.")
    }

    /// Empties Recently Deleted. Asks first, through `confirmsEmptyingDeleted`.
    @discardableResult
    func emptyRecentlyDeleted() -> Bool {
        confirmsEmptyingDeleted = false
        let deleted = NoteCollection.deleted(notes)
        guard !deleted.isEmpty else { return true }
        guard removeForGood(deleted, failure: "Recently Deleted couldn't be emptied.") else { return false }
        notice = .success("Recently Deleted is empty")
        return true
    }

    /// Removes notes deleted 60 or more days ago. Runs when the window opens and before the
    /// launcher lists Recently Deleted.
    @discardableResult
    func purgeExpired() -> Int {
        let expired = NoteCollection.expired(notes, now: now())
        guard !expired.isEmpty, !store.isReadOnly, store.fileURL == nil || mayPurgeLibraryOnDisk else { return 0 }
        return removeForGood(expired, failure: nil) ? expired.count : 0
    }

    /// Deletes notes from the library, with their favorite and usage records, then the images
    /// only they used. Images still referenced by any other note, by the words in the editor, or
    /// by a new note not saved yet, stay.
    private func removeForGood(_ purged: [QuickNote], failure: String?) -> Bool {
        guard !purged.isEmpty else { return true }
        let ids = Set(purged.map(\.id))
        let itemIDs = Set(ids.map { "note.\($0)" })
        let removed = store.update { database in
            database.notes.removeAll { ids.contains($0.id) }
            database.favoriteIDs.subtract(itemIDs)
            database.usage.removeAll { itemIDs.contains($0.id) }
        }
        guard removed else {
            if let failure { notice = .error(store.errorMessage ?? failure) }
            return false
        }
        let result = assets.reclaim(
            NoteAssetStore.referencedNames(in: purged), keeping: notes, protecting: protectedImages)
        if !result.failed.isEmpty {
            notice = .warning("Some images couldn't be removed. OpenRay tries again with the next purge.")
        }
        return true
    }

    /// Images a purge must keep: in the editor now, in its Undo history, in a new note not saved
    /// yet, or open in another editor.
    private var protectedImages: Set<String> {
        undoReachableImages.union(
            NoteAssetStore.referencedNames(inTexts: [text] + (draft.map { [$0.content] } ?? []) + externalTexts()))
    }

    /// Another note opened, so the editor's Undo history starts over; images only it could bring
    /// back can go, if a purge left them waiting.
    private func resetUndoReachableImages() {
        undoReachableImages = NoteAssetStore.referencedNames(inTexts: [text])
        guard assets.hasPendingRemovals else { return }
        assets.reclaim([], keeping: notes, protecting: protectedImages)
    }

    // MARK: Quitting

    /// Where words that couldn't be saved before quitting are kept: `NoteRecovery` beside the library.
    var recoveryDirectory: URL {
        assets.directory.deletingLastPathComponent().appending(path: "NoteRecovery", directoryHint: .isDirectory)
    }

    var recoveredFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Before OpenRay quits: saves what's typed, or, when that fails, writes it to a recovery file
    /// so nothing typed is lost. Returns that file.
    @discardableResult
    func prepareForTermination() -> URL? {
        guard hasUnsavedText, !flush(), !isBlank(text) else { return nil }
        return writeRecoveryCopy()
    }

    func writeRecoveryCopy() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = NoteExporter.suggestedFileName(for: QuickNote(title: Self.title(for: text), content: text), format: .markdown)
        let url = recoveryDirectory.appending(path: "\(formatter.string(from: now())) \(base)")
        do {
            try FileManager.default.createDirectory(
                at: recoveryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Once a launch, says where recovered text is.
    private func announceRecoveredText() {
        guard !didAnnounceRecovery else { return }
        didAnnounceRecovery = true
        let count = recoveredFiles.count
        guard count > 0, notice == nil else { return }
        notice = .warning(
            "\(count) note\(count == 1 ? "" : "s") that couldn't be saved before quitting \(count == 1 ? "is" : "are") in Settings › Notes.")
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
