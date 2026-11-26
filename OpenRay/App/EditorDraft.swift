import Foundation
import Observation

/// The working copy behind an inline editor. Snippets and quicklinks save with
/// ⌘S; notes save themselves as you type.
@MainActor
@Observable
final class EditorDraft {
    let editor: LibraryEditor
    let isNew: Bool
    var name: String { didSet { changed() } }
    var keyword: String { didSet { changed() } }
    var content: String { didSet { changed() } }
    var expandsKeyword: Bool { didSet { changed() } }
    private(set) var saveError: String?
    private(set) var savedAt: Date?
    private(set) var attemptedSave = false
    /// Bumped when validation blocks a save, so the editor can focus the first invalid field.
    private(set) var invalidFocusRequest = 0
    /// The values as last loaded or saved. Observed, so the dirty and saved labels follow it.
    private var original: [String]
    /// Called on every edit, before notes schedule their autosave.
    @ObservationIgnored var onEdit: (() -> Void)?
    @ObservationIgnored private weak var store: LibraryStore?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    init(editor: LibraryEditor, store: LibraryStore) {
        self.editor = editor
        self.store = store
        let values: (name: String, keyword: String, content: String, expands: Bool, isNew: Bool, saved: Date?)
        switch editor {
        case .quicklink(let item):
            values = (item.name, item.keyword, item.template, true, !store.database.quicklinks.contains { $0.id == item.id }, nil)
        case .snippet(let item):
            values = (
                item.name, item.keyword, item.content, item.expandsAsYouType,
                !store.database.snippets.contains { $0.id == item.id }, nil
            )
        case .note(let item):
            let isNew = !store.database.notes.contains { $0.id == item.id }
            values = (item.title, "", item.content, false, isNew, isNew ? nil : item.modifiedAt)
        }
        name = values.name
        keyword = values.keyword
        content = values.content
        expandsKeyword = values.expands
        isNew = values.isNew
        savedAt = values.saved
        original = [values.name, values.keyword, values.content, String(values.expands)]
    }

    var isNote: Bool { if case .note = editor { true } else { false } }
    var isSnippet: Bool { if case .snippet = editor { true } else { false } }
    var isQuicklink: Bool { if case .quicklink = editor { true } else { false } }

    var isDirty: Bool { currentValues != original }

    private var currentValues: [String] { [name, keyword, content, String(expandsKeyword)] }

    var title: String {
        switch editor {
        case .snippet: isNew ? "New Snippet" : (name.isEmpty ? "Snippet" : name)
        case .quicklink: isNew ? "New Quicklink" : (name.isEmpty ? "Quicklink" : name)
        case .note:
            name.trimmingCharacters(in: .whitespaces).isEmpty
                ? (QuickNote.derivedTitle(from: content).isEmpty ? "New Note" : QuickNote.derivedTitle(from: content))
                : name
        }
    }

    // MARK: Validation, as you type

    var nameError: String? {
        guard attemptedSave, !isNote, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return isSnippet ? "Give this snippet a name." : "Give this quicklink a name."
    }

    var keywordError: String? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !isNote, let store else { return nil }
        if isSnippet {
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789;:/._-")
            guard keyword.unicodeScalars.allSatisfy(allowed.contains) else {
                return "Use letters, numbers and ; : / . _ - without spaces."
            }
            guard keyword.count >= 2 || !attemptedSave else { return "Use at least 2 characters." }
            guard keyword.count <= 32 else { return "Use at most 32 characters." }
        } else {
            guard !keyword.contains(where: \.isWhitespace) else { return "Keywords can't contain spaces." }
            guard keyword.count <= 32 else { return "Use at most 32 characters." }
        }
        let normalized = CommandBinding.normalizedAlias(keyword)
        let ownID: UUID? =
            switch editor {
            case .snippet(let item): item.id
            case .quicklink(let item): item.id
            case .note: nil
            }
        // Older libraries can hold clashes the store never rejected. Only a keyword
        // you typed is checked, so such an item can still be renamed or edited.
        if normalized != CommandBinding.normalizedAlias(original[1]) {
            if let other = store.database.snippets.first(where: {
                $0.id != ownID && CommandBinding.normalizedAlias($0.keyword) == normalized
            }) {
                return "“\(keyword)” is already used by \(other.name)."
            }
            if let other = store.database.quicklinks.first(where: {
                $0.id != ownID && CommandBinding.normalizedAlias($0.keyword) == normalized
            }) {
                return "“\(keyword)” is already used by \(other.name)."
            }
        }
        if store.database.aliasTarget(for: keyword) != nil {
            return "“\(keyword)” is already a command alias."
        }
        return nil
    }

    var contentError: String? {
        switch editor {
        case .quicklink:
            let template = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard attemptedSave || (template.count > 8 && template != "https://") else { return nil }
            do {
                try Quicklink(name: "Check", template: template, keyword: "").validate()
                return nil
            } catch {
                return error.localizedDescription
            }
        case .snippet:
            guard attemptedSave else { return nil }
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add the text to paste." }
            return content.count > 32_000 ? "Snippets support up to 32,000 characters." : nil
        case .note:
            return content.count > 100_000 ? "Notes support up to 100,000 characters." : nil
        }
    }

    var canSave: Bool { keywordError == nil && (contentError == nil || !attemptedSave) }

    // MARK: Previews

    var snippetPreview: String { Snippet(name: name, keyword: keyword, content: content).expanded() }

    var quicklinkPreview: (url: String, valid: Bool) {
        let link = Quicklink(name: name, template: content, keyword: keyword)
        if let url = try? link.resolvedURL(query: link.needsQuery ? "swift concurrency" : "") {
            return (url.absoluteString, true)
        }
        return (content.isEmpty ? "https://example.com/search?q={query}" : content, false)
    }

    // MARK: Saving

    /// Saves snippets and quicklinks. Returns false and shows the reason when it can't.
    func save() -> Bool {
        attemptedSave = true
        guard let store else { return false }
        if nameError != nil || keywordError != nil || contentError != nil {
            invalidFocusRequest += 1
            return false
        }
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: Bool
        switch editor {
        case .quicklink(var item):
            item.name = name
            item.keyword = keyword
            item.template = content.trimmingCharacters(in: .whitespacesAndNewlines)
            saved = store.save(item)
        case .snippet(var item):
            item.name = name
            item.keyword = keyword
            item.content = content
            item.expandsKeyword = expandsKeyword ? nil : false
            saved = store.save(item)
        case .note:
            return saveNote()
        }
        saveError = saved ? nil : (store.errorMessage ?? "This library is read-only. Your original data is unchanged.")
        return saved
    }

    var isEmptyNote: Bool {
        isNote && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Once this editor's words had to go to a note of their own (both editors changed the same
    /// field, or the note was deleted elsewhere), saves go there.
    @ObservationIgnored private var redirectedNoteID: UUID?

    /// The library note this editor writes to.
    var noteID: UUID? {
        guard case .note(let note) = editor else { return nil }
        return redirectedNoteID ?? note.id
    }

    /// Shows what another editor saved, in the fields not edited here since the last save.
    func refreshCleanFields() {
        guard let store, let id = noteID, let stored = store.database.notes.first(where: { $0.id == id }), !stored.isDeleted
        else { return }
        if name == original[0], stored.title != name {
            name = stored.title
            original[0] = stored.title
        }
        if content == original[2], stored.content != content {
            content = stored.content
            original[2] = stored.content
        }
    }

    /// Saves the note if it changed since the last save. Empty notes are skipped,
    /// so clearing the text mid-edit never deletes anything.
    ///
    /// It writes only the fields changed here onto the note as saved now, so a pin, or newer
    /// words from the Notes window, stay. When the Notes window changed the same field since this
    /// editor's last save, or the note was deleted elsewhere, these words become a new note
    /// instead, so neither version is lost and nothing deleted comes back.
    @discardableResult
    func saveNote() -> Bool {
        autosaveTask?.cancel()
        guard case .note(let opened) = editor, let store else { return false }
        guard !isEmptyNote else { return true }
        guard isDirty || savedAt == nil else { return true }
        let snapshot = currentValues
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = redirectedNoteID ?? opened.id
        let wasSaved = !isNew || savedAt != nil || redirectedNoteID != nil
        var note: QuickNote
        var message: String?
        if let stored = store.database.notes.first(where: { $0.id == targetID }), !stored.isDeleted {
            let titleHere = name != original[0]
            let bodyHere = content != original[2]
            let titleClash = titleHere && stored.title != original[0].trimmingCharacters(in: .whitespacesAndNewlines)
                && stored.title != title
            let bodyClash = bodyHere && stored.content != original[2] && stored.content != content
            if titleClash || bodyClash {
                note = QuickNote(title: title, content: content)
                message = "This note changed in the Notes window, so these edits were saved as a new note."
            } else {
                note = stored
                if titleHere { note.title = title }
                if bodyHere { note.content = content }
            }
        } else if wasSaved {
            note = QuickNote(title: title, content: content)
            message = "This note was deleted elsewhere, so these edits were saved as a new note."
        } else {
            note = opened
            note.title = title
            note.content = content
        }
        if store.save(note) {
            if note.id != opened.id { redirectedNoteID = note.id }
            // The saved text is the new baseline, so editing back to it saves again.
            original = snapshot
            savedAt = .now
            saveError = message
            return true
        }
        saveError = store.errorMessage ?? "This note couldn't be saved."
        return false
    }

    /// Called as the note editor closes. Saves the note, or moves a stored note that was emptied
    /// to Recently Deleted, unless another editor saved it since, which keeps that version.
    /// Returns false, with the reason in `saveError`, when neither worked.
    @discardableResult
    func finishNote() -> Bool {
        autosaveTask?.cancel()
        guard isNote, let store, let id = noteID else { return false }
        guard isEmptyNote else { return saveNote() }
        guard let stored = store.database.notes.first(where: { $0.id == id }), !stored.isDeleted else { return true }
        // Newer words saved elsewhere since this editor's last save stay. (Only the body is compared:
        // the library derives a title this editor never typed.)
        guard stored.content == original[2] else { return true }
        let itemID = "note.\(id)"
        let removed = store.update { database in
            database.moveNoteToRecentlyDeleted(id)
            database.favoriteIDs.remove(itemID)
            database.usage.removeAll { $0.id == itemID }
        }
        saveError = removed ? nil : (store.errorMessage ?? "This note couldn't be removed.")
        return removed
    }

    private func changed() {
        onEdit?()
        guard isNote else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            self?.saveNote()
        }
    }
}
