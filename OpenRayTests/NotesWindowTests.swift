import AppKit
import Foundation
import Testing

@testable import OpenRay

// MARK: - Fakes

@MainActor
final class FakeNotesPresenter: NotesWindowPresenting {
    var isVisible = false
    var allowsShowing = true
    /// Set to model a window that's visible but behind other apps.
    var keyOverride: Bool?
    private(set) var showCount = 0

    var isKey: Bool { keyOverride ?? isVisible }

    func show() -> Bool {
        showCount += 1
        isVisible = allowsShowing
        return allowsShowing
    }

    func hide() { isVisible = false }
}

@MainActor
final class FakeNoteExport: NoteExportDestination {
    var url: URL?
    private(set) var asked: [(name: String, format: NoteExportFormat)] = []

    func chooseURL(suggestedName: String, format: NoteExportFormat) async -> URL? {
        asked.append((suggestedName, format))
        return url
    }
}

@MainActor
final class FakeImagePicker: NoteImagePicking {
    var url: URL?
    func chooseImage() async -> URL? { url }
}

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

@MainActor
struct NotesHarness {
    let store: LibraryStore
    let model: NotesWindowModel
    let presenter = FakeNotesPresenter()
    let export = FakeNoteExport()
    let picker = FakeImagePicker()
    let clock: TestClock
    let assetsDirectory: URL

    init(store: LibraryStore = LibraryStore(fileURL: nil), clock: TestClock = TestClock()) {
        self.store = store
        self.clock = clock
        // A folder of its own, so NoteRecovery beside NoteAssets is per test too.
        assetsDirectory = FileManager.default.temporaryDirectory.appending(path: "OpenRayNotesTest-\(UUID())")
            .appending(path: NoteAssetStore.folderName)
        model = NotesWindowModel(
            store: store, assets: NoteAssetStore(directory: assetsDirectory), now: { clock.now }, exportDestination: export,
            imagePicker: picker)
        model.presenter = presenter
    }

    /// Types `text` into the open note and saves it.
    func write(_ text: String) {
        model.edit(text)
        model.flush()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: assetsDirectory.deletingLastPathComponent()) }
}

// MARK: - Model and storage

@MainActor
struct NotesWindowTests {
    // MARK: QuickNote migration

    @Test func notesFromEarlierLibrariesDecodeWithoutTheNewFieldsAndEncodeUnchanged() throws {
        let legacy = """
            {"id":"6E0B7C9A-8F3A-4C55-9B9A-2E6D1F0C4A11","title":"Old","content":"Plain text","modifiedAt":700000000}
            """
        let note = try JSONDecoder().decode(QuickNote.self, from: Data(legacy.utf8))
        #expect(note.title == "Old")
        #expect(note.pinnedIndex == nil && note.deletedAt == nil && note.formatVersion == nil)
        #expect(!note.isMarkdown)
        // Untouched notes write exactly the keys they had, so an earlier build reads them as before.
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        #expect(Set(encoded.keys) == ["id", "title", "content", "modifiedAt"])

        var pinned = note
        pinned.pinnedIndex = 2
        pinned.deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        pinned.formatVersion = QuickNote.markdownFormat
        let roundTrip = try JSONDecoder().decode(QuickNote.self, from: JSONEncoder().encode(pinned))
        #expect(roundTrip == pinned)
    }

    @Test func aLibraryWithOldNotesLoadsAndSavesThem() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayNotesMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        var legacy = LibraryDatabase()
        legacy.schemaVersion = 4
        legacy.notes = [QuickNote(title: "Keep", content: "From 2.0")]
        try JSONEncoder().encode(legacy).write(to: url)

        let store = LibraryStore(fileURL: url)
        #expect(!store.isReadOnly)
        #expect(store.database.liveNotes.map(\.title) == ["Keep"])
        #expect(store.update { _ in })
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let notes = try #require(saved["notes"] as? [[String: Any]])
        #expect(notes.first?["pinnedIndex"] == nil && notes.first?["deletedAt"] == nil)
    }

    @Test func titlesComeFromTheFirstLineWithoutMarkup() {
        #expect(QuickNote.markdownTitle(from: "\n# Groceries\n- milk") == "Groceries")
        #expect(QuickNote.markdownTitle(from: "- [ ] **Call** [Sam](https://x.y)") == "Call Sam")
        #expect(QuickNote.markdownTitle(from: "![shot](NoteAssets/a.png)") == "Image")
        #expect(QuickNote.markdownTitle(from: "```\ncode") == "code")
        #expect(QuickNote.derivedTitle(from: "## Plan\nbody") == "Plan")
        #expect(QuickNote(title: "# Old", content: "# Old\nx").titleFollowsContent)
        #expect(!QuickNote(title: "Typed title", content: "Body").titleFollowsContent)
    }

    // MARK: Pins and order

    @Test func pinsTakeTheNextSlotAndCloseGapsWhenRemoved() throws {
        var notes = (0..<3).map { QuickNote(title: "N\($0)", content: "N\($0)", modifiedAt: Date(timeIntervalSince1970: Double($0))) }
        #expect(try NoteCollection.togglePin(notes[2].id, in: &notes))
        #expect(try NoteCollection.togglePin(notes[0].id, in: &notes))
        #expect(try NoteCollection.togglePin(notes[1].id, in: &notes))
        #expect(NoteCollection.pinned(notes).map(\.title) == ["N2", "N0", "N1"])
        // Unpinning the first closes the gap, so ⌘1 and ⌘2 stay filled.
        #expect(try NoteCollection.togglePin(notes[2].id, in: &notes) == false)
        #expect(NoteCollection.pinned(notes).map(\.pinnedIndex) == [0, 1])
        NoteCollection.movePin(notes[1].id, by: -1, in: &notes)
        #expect(NoteCollection.pinned(notes).map(\.title) == ["N1", "N0"])
        // Pinned first, then the most recently edited.
        #expect(NoteCollection.ordered(notes).map(\.title) == ["N1", "N0", "N2"])
    }

    @Test func pinsStopAtTenAndSkipDeletedNotes() throws {
        var notes = (0..<11).map { QuickNote(title: "N\($0)", content: "x") }
        for note in notes.prefix(10) { try NoteCollection.togglePin(note.id, in: &notes) }
        #expect(throws: NoteCollection.PinError.full) { try NoteCollection.togglePin(notes[10].id, in: &notes) }
        NoteCollection.moveToRecentlyDeleted(notes[0].id, at: .now, in: &notes)
        #expect(notes[0].pinnedIndex == nil)
        #expect(NoteCollection.pinned(notes).map(\.pinnedIndex) == Array(0..<9))
        #expect(throws: NoteCollection.PinError.deleted) { try NoteCollection.togglePin(notes[0].id, in: &notes) }
    }

    // MARK: Recently Deleted

    @Test func recentlyDeletedExpiresAfterSixtyDaysOnTheInjectedClock() {
        let clock = TestClock()
        var notes = [QuickNote(title: "Gone", content: "x"), QuickNote(title: "Fresh", content: "y")]
        NoteCollection.moveToRecentlyDeleted(notes[0].id, at: clock.now, in: &notes)
        clock.advance(days: 30)
        NoteCollection.moveToRecentlyDeleted(notes[1].id, at: clock.now, in: &notes)
        clock.advance(days: 29.9)
        #expect(NoteCollection.expired(notes, now: clock.now).isEmpty)
        clock.advance(days: 0.1)
        #expect(NoteCollection.expired(notes, now: clock.now).map(\.title) == ["Gone"])
        clock.advance(days: 30)
        #expect(Set(NoteCollection.expired(notes, now: clock.now).map(\.title)) == ["Gone", "Fresh"])
    }

    @Test func openingTheWindowPurgesExpiredNotesAndTheirImages() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        let reference = try harness.model.assets.save(Data([1, 2, 3]), fileExtension: "png")
        harness.model.show()
        harness.write("Old\n![Image](\(reference))")
        harness.model.deleteCurrentNote()
        #expect(harness.model.deletedNotes.count == 1)
        harness.clock.advance(days: 59)
        harness.model.show()
        #expect(harness.model.deletedNotes.count == 1)
        harness.clock.advance(days: 1)
        harness.model.show()
        #expect(harness.model.deletedNotes.isEmpty)
        let file = try #require(harness.model.assets.url(for: reference))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func deleteRestoreAndEmptyRecentlyDeleted() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("First")
        harness.model.newNote()
        harness.write("Second")
        let second = harness.model.currentID
        harness.model.deleteCurrentNote()
        // The note before it opens.
        #expect(harness.model.currentNote?.title == "First")
        #expect(harness.model.deletedNotes.map(\.title) == ["Second"])
        #expect(harness.model.notice?.text.contains("Recently Deleted") == true)
        // Restore brings it back and opens it.
        harness.model.restore(second!)
        #expect(harness.model.currentNote?.title == "Second")
        #expect(harness.model.deletedNotes.isEmpty)
        harness.model.deleteCurrentNote()
        harness.model.emptyRecentlyDeleted()
        #expect(harness.store.database.notes.map(\.title) == ["First"])
    }

    // MARK: Writing and navigation

    @Test func aNewNoteIsSavedOnlyOnceItHasWords() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        #expect(harness.model.show())
        #expect(harness.presenter.isVisible)
        #expect(harness.model.isDraft)
        harness.write("   ")
        #expect(harness.store.database.notes.isEmpty)
        harness.write("# Plan\n- [ ] ship")
        let note = harness.store.database.notes.first
        #expect(note?.title == "Plan")
        #expect(note?.formatVersion == QuickNote.markdownFormat)
        #expect(note?.modifiedAt == harness.clock.now)
        #expect(!harness.model.isDraft)
    }

    @Test func theTitleFollowsTheFirstLineUnlessItWasTyped() {
        let store = LibraryStore(fileURL: nil)
        let typed = QuickNote(title: "My title", content: "Body")
        store.update { $0.notes = [typed] }
        let harness = NotesHarness(store: store)
        defer { harness.cleanUp() }
        harness.model.show(noteID: typed.id)
        harness.write("New body")
        #expect(store.database.notes.first?.title == "My title")
        harness.model.newNote()
        harness.write("One")
        harness.write("Two\nmore")
        #expect(store.database.notes.first { $0.content.hasPrefix("Two") }?.title == "Two")
    }

    @Test func leavingANoteYouEmptiedMovesItToRecentlyDeletedWithItsWords() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Keep")
        harness.model.newNote()
        harness.write("Temporary words")
        harness.write("")
        // The emptied note keeps its last words while it's open…
        #expect(harness.store.database.notes.first { $0.title == "Temporary words" }?.content == "Temporary words")
        harness.model.goBack()
        // …and leaving it moves it to Recently Deleted with them, never deleting it for good.
        #expect(harness.model.currentNote?.title == "Keep")
        #expect(harness.model.deletedNotes.map(\.content) == ["Temporary words"])
        #expect(harness.store.database.liveNotes.map(\.title) == ["Keep"])
    }

    // MARK: Review regressions: data loss

    /// OpenRay 0.1 saved notes with a title and an empty body.
    private static let titleOnlyNoteJSON = """
        {"id":"9B5E2C1A-0C3D-4E5F-8A9B-1C2D3E4F5A6B","title":"Call the bank","content":"","modifiedAt":700000000}
        """

    @Test func openingAndClosingATitleOnlyNoteFromOpenRay01KeepsIt() throws {
        let legacy = try JSONDecoder().decode(QuickNote.self, from: Data(Self.titleOnlyNoteJSON.utf8))
        let store = LibraryStore(fileURL: nil)
        store.update { $0.notes = [legacy, QuickNote(title: "Other", content: "Other")] }
        let harness = NotesHarness(store: store)
        defer { harness.cleanUp() }
        harness.model.show(noteID: legacy.id)
        #expect(harness.model.displayTitle == "Call the bank")
        harness.model.hide()
        harness.model.show(noteID: legacy.id)
        let other = store.database.notes.first { $0.title == "Other" }!.id
        harness.model.open(other)
        harness.model.goBack()
        harness.model.newNote()
        #expect(store.database.notes.first { $0.id == legacy.id } == legacy)
        // Typing into it and clearing it again keeps it too: it has a title of its own.
        harness.model.open(legacy.id)
        harness.write("draft")
        harness.write("")
        harness.model.hide()
        let kept = try #require(store.database.notes.first { $0.id == legacy.id })
        #expect(kept.title == "Call the bank" && kept.content.isEmpty && !kept.isDeleted)
    }

    @Test func aSaveThatFailsForLengthKeepsTheNoteOpenUntilItSavesOrIsDiscarded() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Short")
        let id = try #require(harness.model.currentID)
        harness.model.newNote()
        harness.write("Other")
        harness.model.open(id)
        let tooLong = "Short " + String(repeating: "x", count: QuickNote.maximumLength)
        harness.model.edit(tooLong)
        #expect(!harness.model.flush())
        #expect(harness.model.saveFailed)
        // Every way out keeps the note open, with its words, and says why.
        harness.model.newNote()
        harness.model.goBack()
        harness.model.goForward()
        harness.model.openPinned(digit: 1)
        harness.model.deleteCurrentNote()
        harness.model.hide()
        #expect(harness.model.currentID == id)
        #expect(harness.model.text == tooLong)
        #expect(harness.presenter.isVisible)
        #expect(harness.model.notice?.text.contains("100,000") == true)
        #expect(harness.store.database.notes.first { $0.id == id }?.isDeleted == false)
        // Shortening it saves, and then switching works.
        harness.write("Short and saved")
        #expect(!harness.model.saveFailed)
        harness.model.newNote()
        #expect(harness.model.isDraft)
        #expect(harness.store.database.notes.first { $0.id == id }?.content == "Short and saved")
    }

    @Test func aFailedWriteKeepsTheWordsAndDiscardRestoresTheSavedNote() throws {
        // An unreadable library opens read-only, so every save fails, as a full disk would.
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayReadOnly-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.json")
        try Data("not json".utf8).write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.isReadOnly)
        let harness = NotesHarness(store: store)
        defer { harness.cleanUp() }
        harness.model.show()
        harness.model.edit("Words I typed")
        #expect(!harness.model.flush())
        harness.model.newNote()
        harness.model.hide()
        #expect(harness.model.text == "Words I typed")
        #expect(harness.presenter.isVisible)
        harness.model.discardUnsavedChanges()
        #expect(harness.model.text.isEmpty && !harness.model.saveFailed)
        harness.model.hide()
        #expect(!harness.presenter.isVisible)
    }

    @Test func theWindowShowsEditsSavedElsewhereAndNeverOverwritesThem() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Plan\nfirst")
        let id = try #require(harness.model.currentID)
        // The inline editor saves the same note while the window is idle…
        harness.store.update { database in
            let index = database.notes.firstIndex { $0.id == id }!
            database.notes[index].content = "Plan\nfrom the launcher"
        }
        // …and coming back to the window shows it.
        harness.model.reloadIfChangedElsewhere()
        #expect(harness.model.text == "Plan\nfrom the launcher")
        // A buffer edited before the other save doesn't overwrite it: its words become a new note.
        harness.model.edit("Plan\nwindow edit")
        harness.store.update { database in
            let index = database.notes.firstIndex { $0.id == id }!
            database.notes[index].content = "Plan\nlauncher again"
        }
        #expect(harness.model.flush())
        #expect(harness.store.database.notes.first { $0.id == id }?.content == "Plan\nlauncher again")
        #expect(harness.store.database.notes.contains { $0.id != id && $0.content == "Plan\nwindow edit" })
        #expect(harness.model.currentID != id)
        #expect(harness.model.notice?.tone == .warning)
        // Opening the note that's already open picks up what was saved elsewhere.
        harness.model.open(id)
        #expect(harness.model.text == "Plan\nlauncher again")
    }

    @Test func theInlineEditorWritesOnlyWhatItChanged() throws {
        let store = LibraryStore(fileURL: nil)
        let original = QuickNote(title: "Trip", content: "Old body")
        store.update { $0.notes = [original] }
        let draft = EditorDraft(editor: .note(original), store: store)
        // Meanwhile the Notes window writes a newer body and pins the note.
        store.update { database in
            database.notes[0].content = "Newer body from the window"
            try NoteCollection.togglePin(original.id, in: &database.notes)
        }
        draft.name = "Trip to Lisbon"
        #expect(draft.saveNote())
        let saved = try #require(store.database.notes.first)
        #expect(saved.title == "Trip to Lisbon")
        #expect(saved.content == "Newer body from the window")
        #expect(saved.pinnedIndex == 0)
        // Refreshing shows the newer body, so a body edited after that is written, pin kept.
        draft.refreshCleanFields()
        #expect(draft.content == "Newer body from the window")
        draft.content = "Body from the inline editor"
        #expect(draft.saveNote())
        #expect(store.database.notes.first { $0.id == original.id }?.content == "Body from the inline editor")
        #expect(store.database.notes.first { $0.id == original.id }?.pinnedIndex == 0)
    }

    // MARK: Re-review regressions

    private func tooLong(_ prefix: String) -> String { prefix + " " + String(repeating: "x", count: QuickNote.maximumLength) }

    @Test func openNotesKeepsUnsavedTextWhenItsNoteIsDeletedElsewhere() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("A saved")
        let id = try #require(harness.model.currentID)
        let unsavable = tooLong("A")
        harness.model.edit(unsavable)
        #expect(!harness.model.flush())
        // The launcher moves A to Recently Deleted, then Open Notes runs.
        harness.store.update { $0.moveNoteToRecentlyDeleted(id, at: harness.clock.now) }
        harness.model.show()
        #expect(harness.model.text == unsavable)
        #expect(harness.model.saveFailed)
        #expect(harness.model.deletedNotes.map(\.content) == ["A saved"])
        // Words that can be saved become a note of their own instead.
        harness.model.edit("A rescued")
        harness.model.show()
        #expect(harness.store.database.liveNotes.map(\.content) == ["A rescued"])
        #expect(harness.model.currentID != id)
    }

    @Test func quittingWritesARecoveryCopyWhenTheSaveFails() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Saved fine")
        #expect(harness.model.prepareForTermination() == nil)
        let unsavable = tooLong("Draft")
        harness.model.edit(unsavable)
        let file = try #require(harness.model.prepareForTermination())
        #expect(try String(contentsOf: file, encoding: .utf8) == unsavable)
        #expect(harness.model.recoveredFiles.map(\.lastPathComponent) == [file.lastPathComponent])
        #expect(file.deletingLastPathComponent().standardizedFileURL == harness.model.recoveryDirectory.standardizedFileURL)
    }

    @Test func deletingANewNoteKeepsWordsThatCantSaveAndTrashesOnesThatCan() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        let unsavable = tooLong("New")
        harness.model.edit(unsavable)
        harness.model.deleteCurrentNote()
        #expect(harness.model.isDraft && harness.model.text == unsavable)
        #expect(harness.model.notice?.text.contains("100,000") == true)
        harness.model.edit("Keep me recoverable")
        harness.model.deleteCurrentNote()
        #expect(harness.model.deletedNotes.map(\.content) == ["Keep me recoverable"])
    }

    @Test func discardWorksWhenTheNoteWasPurgedMeanwhile() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Other")
        harness.model.newNote()
        harness.write("Doomed")
        let id = try #require(harness.model.currentID)
        harness.model.edit(tooLong("Doomed"))
        #expect(!harness.model.flush())
        harness.store.update { $0.notes.removeAll { $0.id == id } }
        harness.model.discardUnsavedChanges()
        #expect(!harness.model.saveFailed)
        #expect(harness.model.currentNote?.title == "Other")
    }

    @Test func anEmptiedWindowBufferNeverTrashesANewerSaveFromTheInlineEditor() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Idea\nfirst")
        let id = try #require(harness.model.currentID)
        harness.model.edit("")
        // The inline editor saves newer words before the window is closed.
        harness.store.update { database in
            let index = database.notes.firstIndex { $0.id == id }!
            database.notes[index].content = "Idea\nnewer"
        }
        harness.model.hide()
        let note = try #require(harness.store.database.notes.first { $0.id == id })
        #expect(note.content == "Idea\nnewer" && !note.isDeleted)
    }

    @Test func deleteNoteAfterAConflictCopyDeletesTheCopyNotTheOtherEditorsNote() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Shared\nbase")
        let id = try #require(harness.model.currentID)
        harness.model.edit("Shared\nwindow edit")
        harness.store.update { database in
            let index = database.notes.firstIndex { $0.id == id }!
            database.notes[index].content = "Shared\ninline edit"
        }
        harness.model.deleteCurrentNote()
        let original = try #require(harness.store.database.notes.first { $0.id == id })
        #expect(original.content == "Shared\ninline edit" && !original.isDeleted)
        #expect(harness.model.deletedNotes.map(\.content) == ["Shared\nwindow edit"])
    }

    @Test func theInlineEditorKeepsBothVersionsWhenTheSameFieldChangedInBoth() throws {
        let store = LibraryStore(fileURL: nil)
        let original = QuickNote(title: "Plan", content: "Plan\nold")
        store.update { $0.notes = [original] }
        let draft = EditorDraft(editor: .note(original), store: store)
        // The window saves a newer body while the inline draft is retained.
        store.update { $0.notes[0].content = "Plan\nnewer" }
        draft.content = "Plan\nold!"
        #expect(draft.saveNote())
        #expect(store.database.notes.first { $0.id == original.id }?.content == "Plan\nnewer")
        let copy = try #require(store.database.notes.first { $0.id != original.id })
        #expect(copy.content == "Plan\nold!")
        #expect(draft.saveError?.contains("new note") == true)
        // Later edits go to that new note, never back over the original.
        draft.content = "Plan\nold!!"
        #expect(draft.saveNote())
        #expect(store.database.notes.first { $0.id == copy.id }?.content == "Plan\nold!!")
        #expect(store.database.notes.first { $0.id == original.id }?.content == "Plan\nnewer")
        #expect(draft.noteID == copy.id)
    }

    @Test func emptyingANoteInTheInlineEditorMovesItToRecentlyDeleted() throws {
        let store = LibraryStore(fileURL: nil)
        let note = QuickNote(title: "Errand", content: "Buy stamps")
        store.update { $0.notes = [note] }
        let draft = EditorDraft(editor: .note(note), store: store)
        draft.name = ""
        draft.content = ""
        #expect(draft.finishNote())
        #expect(store.database.notes.first?.isDeleted == true)
        #expect(store.database.notes.first?.content == "Buy stamps")
        // Emptied after the window saved newer words: those stay.
        let other = QuickNote(title: "Kept", content: "Old")
        store.update { $0.notes.append(other) }
        let second = EditorDraft(editor: .note(other), store: store)
        store.update { database in database.notes[database.notes.firstIndex { $0.id == other.id }!].content = "Newer" }
        second.name = ""
        second.content = ""
        #expect(second.finishNote())
        #expect(store.database.notes.first { $0.id == other.id }?.isDeleted == false)
    }

    @Test func theInlineEditorNeverRevivesANoteDeletedElsewhere() throws {
        let store = LibraryStore(fileURL: nil)
        let purged = QuickNote(title: "Gone", content: "Gone body")
        let trashed = QuickNote(title: "Trashed", content: "Trashed body")
        store.update { $0.notes = [purged, trashed] }
        let draftOfPurged = EditorDraft(editor: .note(purged), store: store)
        let draftOfTrashed = EditorDraft(editor: .note(trashed), store: store)
        store.update { database in
            database.notes.removeAll { $0.id == purged.id }
            database.moveNoteToRecentlyDeleted(trashed.id)
        }
        draftOfPurged.content = "Gone body, edited"
        #expect(draftOfPurged.saveNote())
        #expect(!store.database.notes.contains { $0.id == purged.id })
        #expect(store.database.liveNotes.contains { $0.content == "Gone body, edited" })
        #expect(draftOfPurged.saveError?.contains("deleted elsewhere") == true)
        draftOfTrashed.content = "Trashed body, edited"
        #expect(draftOfTrashed.saveNote())
        #expect(store.database.notes.first { $0.id == trashed.id }?.content == "Trashed body")
        #expect(store.database.liveNotes.contains { $0.content == "Trashed body, edited" })
    }

    @Test func purgeKeepsAnImageUndoCanBringBackUntilThatHistoryIsGone() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        let kept = try harness.model.assets.save(Data([1]), fileExtension: "png")
        let released = try harness.model.assets.save(Data([2]), fileExtension: "png")
        // A trashed note and an open note share both images.
        let trashed = QuickNote(
            title: "First", content: "![Image](\(kept))\n![Image](\(released))", deletedAt: harness.clock.now)
        let open = QuickNote(title: "Second", content: "Second\n![Image](\(kept))\n![Image](\(released))")
        harness.store.update { $0.notes = [trashed, open, QuickNote(title: "Third", content: "Third")] }
        harness.model.show(noteID: open.id)
        // The image lines are removed and saved, then the first note is deleted for good.
        harness.write("Second")
        #expect(harness.model.deletePermanently(trashed.id))
        let keptFile = try #require(harness.model.assets.url(for: kept))
        let releasedFile = try #require(harness.model.assets.url(for: released))
        #expect(FileManager.default.fileExists(atPath: keptFile.path))
        #expect(FileManager.default.fileExists(atPath: releasedFile.path))
        // Undo brings one line back, and its file is still there.
        harness.write("Second\n![Image](\(kept))")
        // Opening another note ends that Undo history: the image nothing uses goes, the other stays.
        let third = harness.store.database.notes.first { $0.title == "Third" }!.id
        harness.model.open(third)
        #expect(FileManager.default.fileExists(atPath: keptFile.path))
        #expect(!FileManager.default.fileExists(atPath: releasedFile.path))
        #expect(!harness.model.assets.hasPendingRemovals)
    }

    @Test func aFailedImageRemovalIsRetriedLater() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayAssetRetry-\(UUID())")
        let assets = NoteAssetStore(directory: directory)
        let reference = try assets.save(Data([1]), fileExtension: "png")
        let name = try #require(NoteAssetStore.fileName(in: reference))
        let file = try #require(assets.url(for: reference))
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: directory)
        }
        // A locked file can't be removed: it's reported and remembered…
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let first = assets.reclaim([name], keeping: [], protecting: [])
        #expect(first.failed == [name])
        #expect(assets.pendingRemovals() == [name])
        // …and the next reclaim, with no candidates of its own, retries it.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        let retry = assets.reclaim([], keeping: [], protecting: [])
        #expect(retry.removed == [name])
        #expect(!assets.hasPendingRemovals)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func expiredNotesLeaveTheBrowserEvenWhileTheWindowStaysOpen() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Old")
        harness.model.deleteCurrentNote()
        harness.model.toggleBrowser()
        harness.model.setBrowserShowsDeleted(true)
        #expect(harness.model.browserResults.count == 1)
        harness.clock.advance(days: 61)
        #expect(harness.model.browserResults.isEmpty)
        #expect(!harness.model.restore(harness.store.database.notes.first!.id))
    }

    @Test func anInertLaunchNeverPurgesALibraryOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayInertPurge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(fileURL: directory.appending(path: "library.json"))
        store.update { $0.notes = [QuickNote(title: "Old", content: "x", deletedAt: .now.addingTimeInterval(-90 * 86_400))] }
        let model = NotesWindowModel(store: store, assets: NoteAssetStore(directory: directory.appending(path: "NoteAssets")))
        #expect(!model.mayPurgeLibraryOnDisk)
        #expect(model.purgeExpired() == 0)
        #expect(store.database.notes.count == 1)
    }

    @Test func purgingOneNoteNeverDeletesAnotherNotesPendingImage() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Old note")
        harness.model.deleteCurrentNote()
        let trashed = try #require(harness.model.deletedNotes.first)
        harness.model.newNote()
        harness.write("Near the limit")
        // An image pasted into a note that can't save yet (it's over the limit).
        let reference = try #require(harness.model.storeImage(Data([1, 2, 3]), fileExtension: "png"))
        harness.model.edit(String(repeating: "x", count: QuickNote.maximumLength) + "\n![Image](\(reference))")
        #expect(!harness.model.flush())
        #expect(harness.model.deletePermanently(trashed.id))
        let file = try #require(harness.model.assets.url(for: reference))
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Only images the purged notes referenced are candidates, and only when nothing keeps them.
        let shared = QuickNote(title: "a", content: "![Image](NoteAssets/S.png) ![Image](NoteAssets/T.png)")
        let keeper = QuickNote(title: "b", content: "![Image](NoteAssets/S.png)")
        #expect(NoteAssetStore.orphans(of: [shared], keeping: [keeper]) == ["T.png"])
        #expect(NoteAssetStore.orphans(of: [shared], keeping: [], protecting: ["![x](NoteAssets/T.png)"]) == ["S.png"])
    }

    @Test func backAndForwardFollowTheNotesYouOpened() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("A")
        harness.model.newNote()
        harness.write("B")
        harness.model.newNote()
        harness.write("C")
        harness.model.goBack()
        #expect(harness.model.currentNote?.title == "B")
        harness.model.goBack()
        #expect(harness.model.currentNote?.title == "A")
        harness.model.goForward()
        #expect(harness.model.currentNote?.title == "B")
        // Opening another note clears forward history, as a browser does.
        let a = harness.store.database.notes.first { $0.title == "A" }!.id
        harness.model.open(a)
        #expect(!harness.model.history.canGoForward)
        harness.model.goBack()
        #expect(harness.model.currentNote?.title == "B")
    }

    @Test func historySkipsNotesThatNoLongerExist() {
        var history = NoteHistory()
        let a = UUID(), b = UUID(), c = UUID()
        history.visit(b, from: a)
        history.visit(c, from: b)
        #expect(history.goBack(from: c) { $0 != b } == a)
        #expect(history.forward == [c])
        #expect(history.goForward(from: a) { _ in true } == c)
    }

    @Test func commandDigitsOpenPinnedNotes() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Pinned one")
        harness.model.togglePin()
        #expect(harness.model.currentPinDigit == 1)
        harness.model.newNote()
        harness.write("Other")
        harness.model.openPinned(digit: 1)
        #expect(harness.model.currentNote?.title == "Pinned one")
        harness.model.openPinned(digit: 5)
        #expect(harness.model.notice?.text.contains("⌘5") == true)
        // A new note without words can't be pinned yet.
        harness.model.newNote()
        harness.model.togglePin()
        #expect(harness.model.notice?.text.contains("Write something") == true)
    }

    @Test func theBrowserSearchesNotesAndRestoresFromRecentlyDeleted() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        harness.write("Groceries\nmilk")
        harness.model.newNote()
        harness.write("Trip plan\npassport")
        harness.model.newNote()
        harness.write("Old idea")
        harness.model.deleteCurrentNote()
        harness.model.toggleBrowser()
        #expect(harness.model.browserResults.count == 2)
        harness.model.setBrowserQuery("passport")
        #expect(harness.model.browserResults.map(\.title) == ["Trip plan"])
        harness.model.openBrowserSelection()
        #expect(harness.model.browser == nil)
        #expect(harness.model.currentNote?.title == "Trip plan")

        harness.model.toggleBrowser()
        harness.model.setBrowserShowsDeleted(true)
        #expect(harness.model.browserResults.map(\.title) == ["Old idea"])
        harness.model.openBrowserSelection()
        #expect(harness.model.currentNote?.title == "Old idea")
        #expect(harness.model.deletedNotes.isEmpty)
    }

    @Test func toggleShowsAndHidesThroughThePresenter() {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.toggle()
        #expect(harness.presenter.isVisible)
        harness.model.toggle()
        #expect(!harness.presenter.isVisible)
        // Visible but behind other apps: toggling brings it forward instead of hiding it.
        harness.model.show()
        harness.presenter.keyOverride = false
        let shows = harness.presenter.showCount
        harness.model.toggle()
        #expect(harness.presenter.isVisible && harness.presenter.showCount == shows + 1)
        harness.presenter.keyOverride = nil
        // A launch that refuses windows reports false, so the launcher can say why.
        harness.presenter.allowsShowing = false
        #expect(!harness.model.show())
    }

    // MARK: Export

    @Test func exportFormatsRenderMarkdownHTMLAndPlainText() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OpenRayExport-\(UUID())")
        let assets = NoteAssetStore(directory: directory)
        let note = QuickNote(
            title: "Plan <A&B>",
            content: """
                # Plan <A&B>
                Some **bold** and _soft_ text with `x < y`.
                - [ ] open
                - [x] done
                1. first
                > quoted
                [Docs](https://example.com)
                ![Image](NoteAssets/AB.png)
                ```
                let a = **b**
                ```
                """, formatVersion: QuickNote.markdownFormat)

        let markdown = NoteExporter.export(note, as: .markdown, assets: assets)
        #expect(markdown.contains("![Image](\(directory.appending(path: "AB.png").absoluteString))"))
        #expect(markdown.contains("- [x] done"))
        #expect(markdown.hasSuffix("```\n"))

        let html = NoteExporter.export(note, as: .html, assets: assets)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<title>Plan &lt;A&amp;B&gt;</title>"))
        #expect(html.contains("<h1>Plan &lt;A&amp;B&gt;</h1>"))
        #expect(html.contains("<strong>bold</strong>") && html.contains("<em>soft</em>"))
        #expect(html.contains("<code>x &lt; y</code>"))
        #expect(html.contains("<ul class=\"tasks\">"))
        #expect(html.contains("<li><input type=\"checkbox\" disabled> open</li>"))
        #expect(html.contains("<li class=\"done\"><input type=\"checkbox\" disabled checked> done</li>"))
        #expect(html.contains("<ol>\n<li>first</li>\n</ol>"))
        #expect(html.contains("<blockquote><p>quoted</p></blockquote>"))
        #expect(html.contains("<a href=\"https://example.com\">Docs</a>"))
        #expect(html.contains("<img src=\"file://"))
        #expect(html.contains("<pre><code>let a = **b**</code></pre>"))

        let text = NoteExporter.export(note, as: .plainText, assets: assets)
        #expect(text.contains("Plan <A&B>\n"))
        #expect(text.contains("Some bold and soft text with x < y."))
        #expect(text.contains("☐ open") && text.contains("☑ done"))
        #expect(text.contains("Docs (https://example.com)"))
        #expect(text.contains("Image: file://"))
        #expect(text.contains("let a = **b**"))
        #expect(!text.contains("```"))
    }

    @Test func exportFileNamesAreSafe() {
        let note = QuickNote(title: "a/b: c\nd", content: "x")
        #expect(NoteExporter.suggestedFileName(for: note, format: .html) == "a-b- c-d.html")
        #expect(NoteExporter.suggestedFileName(for: QuickNote(title: " ", content: ""), format: .markdown) == "Untitled Note.md")
    }

    @Test func exportAsksForAFileThenWritesIt() async throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        harness.model.show()
        // Nothing written yet: there's nothing to export.
        await harness.model.export(.markdown)
        #expect(harness.export.asked.isEmpty)
        harness.write("# Trip\n- [ ] passport")
        let destination = FileManager.default.temporaryDirectory.appending(path: "OpenRayExport-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        // Cancelled: nothing is written.
        await harness.model.export(.plainText)
        #expect(harness.export.asked.map(\.name) == ["Trip.txt"])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        harness.export.url = destination
        await harness.model.export(.plainText)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "Trip\n☐ passport\n")
        #expect(harness.model.notice?.tone == .success)
    }

    @Test func theLiveSavePanelIsRefusedInTests() async {
        let panel = SavePanelNoteExport(guardrail: SideEffectGuard(mode: .testHost))
        #expect(await panel.chooseURL(suggestedName: "a.md", format: .markdown) == nil)
        let picker = OpenPanelImagePicker(guardrail: SideEffectGuard(mode: .verification))
        #expect(await picker.chooseImage() == nil)
    }

    // MARK: Images

    @Test func imagesAreStoredBesideTheLibraryAndOnlyResolveInsideTheirFolder() throws {
        let library = FileManager.default.temporaryDirectory.appending(path: "OpenRayLibrary-\(UUID())/library.json")
        let assets = NoteAssetStore(libraryURL: library)
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        #expect(assets.directory.lastPathComponent == "NoteAssets")
        #expect(assets.directory.deletingLastPathComponent() == library.deletingLastPathComponent())

        let reference = try assets.save(Data([0x89, 0x50]), fileExtension: "PNG")
        #expect(reference.hasPrefix("NoteAssets/") && reference.hasSuffix(".png"))
        #expect(assets.url(for: reference).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(assets.url(for: "NoteAssets/../library.json") == nil)
        #expect(assets.url(for: "/etc/hosts") == nil)
        #expect(assets.url(for: "NoteAssets/.hidden.png") == nil)
        #expect(throws: NoteAssetStore.AssetError.unsupported) { try assets.save(Data(), fileExtension: "exe") }
        #expect(throws: NoteAssetStore.AssetError.tooLarge) {
            try assets.save(Data(count: NoteAssetStore.maximumImageBytes + 1), fileExtension: "png")
        }

        let other = try assets.save(Data([1]), fileExtension: "jpg")
        let unrelated = try assets.save(Data([2]), fileExtension: "png")
        let purged = QuickNote(title: "gone", content: "![Image](\(reference)) ![Image](\(other))")
        let removed = assets.removeAssets(
            referencedBy: [purged], keeping: [QuickNote(title: "x", content: "![Image](\(reference))")])
        #expect(removed == [String(other.dropFirst("NoteAssets/".count))])
        #expect(assets.url(for: reference).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        // A file no purged note referenced is never swept.
        #expect(assets.url(for: unrelated).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func pastedImagesBecomeAReferenceOnTheirOwnLine() throws {
        let harness = NotesHarness()
        defer { harness.cleanUp() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        pasteboard.clearContents()
        pasteboard.setData(image.representation(using: .png, properties: [:]), forType: .png)
        let data = try #require(NoteAssetStore.imageData(from: pasteboard))
        #expect(data.fileExtension == "png")
        let reference = try #require(harness.model.storeImage(data.data, fileExtension: data.fileExtension))
        let edit = NoteMarkdown.insertImage(reference, in: "Shot:", selection: NSRange(location: 5, length: 0))
        #expect(edit.applied(to: "Shot:") == "Shot:\n![Image](\(reference))\n")
    }

    // MARK: Window size

    @Test func theWindowFollowsTheNoteBetweenLimits() {
        #expect(NotesWindowGeometry.height(forContent: 10, screenHeight: 1_000) == NotesWindowGeometry.minimumHeight)
        #expect(NotesWindowGeometry.height(forContent: 300, screenHeight: 1_000) == 300 + NotesWindowGeometry.chrome)
        #expect(NotesWindowGeometry.height(forContent: 5_000, screenHeight: 1_000) == NotesWindowGeometry.maximumHeight)
        #expect(NotesWindowGeometry.height(forContent: 5_000, screenHeight: 600) == 450)
        let frame = NSRect(x: 100, y: 500, width: 460, height: 300)
        let taller = NotesWindowGeometry.frame(frame, resizedTo: 400, within: NSRect(x: 0, y: 0, width: 1_440, height: 900))
        #expect(taller.maxY == frame.maxY && taller.height == 400)
        let clamped = NotesWindowGeometry.frame(frame, resizedTo: 850, within: NSRect(x: 0, y: 0, width: 1_440, height: 900))
        #expect(clamped.minY == 0)
    }
}

// MARK: - Launcher

@MainActor
struct NotesLauncherTests {
    private func makeModel(center: NotesCenter) -> LauncherModel {
        LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [NotesCommandProvider(center: center)]))
    }

    private func fakeCenter(_ presenter: FakeNotesPresenter) -> NotesCenter {
        NotesCenter(makePresenter: { _ in presenter })
    }

    @Test func deletingANoteInTheLauncherMovesItToRecentlyDeleted() throws {
        let model = makeModel(center: fakeCenter(FakeNotesPresenter()))
        model.store.update { $0.notes = [QuickNote(title: "Keep", content: "a"), QuickNote(title: "Drop", content: "b")] }
        let row = try #require(model.noteItems.first { $0.title == "Drop" })
        #expect(model.delete(row))
        #expect(model.store.database.notes.count == 2)
        #expect(model.store.database.notes.first { $0.title == "Drop" }?.isDeleted == true)
        // Deleted notes leave root search and the Notes scope.
        #expect(model.noteItems.map(\.title) == ["Keep"])
        #expect(ActionConfirmation.delete(row).detail.contains("Recently Deleted"))
    }

    @Test func notesCommandsDriveTheWindow() throws {
        let presenter = FakeNotesPresenter()
        let center = fakeCenter(presenter)
        let model = makeModel(center: center)
        let ids = model.commandItems.map(\.id)
        for id in [NotesCommandProvider.toggleID, NotesCommandProvider.createID, NotesCommandProvider.searchID] {
            #expect(ids.contains(id))
        }
        let toggle = try #require(model.commandItems.first { $0.id == NotesCommandProvider.toggleID })
        model.perform(toggle)
        #expect(presenter.isVisible)
        model.perform(toggle)
        #expect(!presenter.isVisible)
        let create = try #require(model.commandItems.first { $0.id == NotesCommandProvider.createID })
        model.perform(create)
        #expect(center.model(for: model.store).isDraft)
        #expect(presenter.isVisible)
        // The same window model serves the same library.
        #expect(center.model(for: model.store) === center.model(for: model.store))
        // Refused windows say so instead of failing silently.
        presenter.allowsShowing = false
        presenter.isVisible = false
        model.perform(toggle)
        #expect(model.feedback?.text.contains("doesn't open") == true)
    }

    @Test func notesCommandsAreBindable() {
        CuratedCommand.$registrations.withValue([NotesCommandProvider.registration]) {
            #expect(CuratedCommand.supports(NotesCommandProvider.toggleID))
            #expect(CuratedCommand.supports(NotesCommandProvider.createID))
        }
        #expect(CommandProviders.all.map(\.id).contains("notes"))
    }

    @Test func recentlyDeletedScopeRestoresAndDeletesForGood() throws {
        let presenter = FakeNotesPresenter()
        let center = fakeCenter(presenter)
        let model = makeModel(center: center)
        let gone = QuickNote(title: "Gone", content: "x", deletedAt: .now)
        let back = QuickNote(title: "Back", content: "y", deletedAt: .now.addingTimeInterval(-60))
        model.store.update { $0.notes = [gone, back] }
        model.navigate(to: .provided(NotesCommandProvider.deletedScope))
        #expect(model.results.map(\.title).sorted() == ["Back", "Gone"])
        let row = try #require(model.results.first { $0.title == "Back" })
        #expect(model.primaryTitle(for: row) == "Restore Note")
        model.perform(row)
        #expect(model.store.database.notes.first { $0.id == back.id }?.isDeleted == false)
        #expect(center.model(for: model.store).currentNote?.id == back.id)

        let goneRow = try #require(model.results.first { $0.title == "Gone" })
        #expect(model.delete(goneRow))
        #expect(!model.store.database.notes.contains { $0.id == gone.id })
    }

    @Test func recentlyDeletedNeverListsOrRestoresNotesPastSixtyDays() throws {
        let presenter = FakeNotesPresenter()
        let model = makeModel(center: fakeCenter(presenter))
        let expired = QuickNote(title: "Ancient", content: "x", deletedAt: .now.addingTimeInterval(-61 * 86_400))
        let recent = QuickNote(title: "Recent", content: "y", deletedAt: .now)
        model.store.update { $0.notes = [expired, recent] }
        model.navigate(to: .provided(NotesCommandProvider.deletedScope))
        #expect(model.results.map(\.title) == ["Recent"])
        // A row for an expired note (an old result, say) can't bring it back, and says so.
        let row = LauncherItem(
            id: "notes.deleted.\(expired.id)", title: "Ancient", subtitle: "", symbol: "note.text", badge: "Deleted",
            action: .provided(ProvidedRef(provider: "notes", id: expired.id.uuidString, payload: "deleted", traits: [.delete])))
        model.perform(row)
        #expect(model.feedback?.style == .warning)
        #expect(!model.store.database.notes.contains { $0.id == expired.id })
    }

    @Test func settingsListsTheSliceSixPanesInOrder() {
        let mine: [SettingsPane] = [.notes, .calendar, .focus, .menuBar]
        #expect(SettingsPane.primary.filter(mine.contains) == mine)
        #expect(SettingsPane(rawValue: "notes") == .notes)
    }
}
