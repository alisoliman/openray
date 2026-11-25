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

    /// Saves the note if it changed since the last save. Empty notes are skipped,
    /// so clearing the text mid-edit never deletes anything.
    @discardableResult
    func saveNote() -> Bool {
        autosaveTask?.cancel()
        guard case .note(var note) = editor, let store else { return false }
        guard !isEmptyNote else { return true }
        guard isDirty || savedAt == nil else { return true }
        let snapshot = currentValues
        note.title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        note.content = content
        if store.save(note) {
            // The saved text is the new baseline, so editing back to it saves again.
            original = snapshot
            savedAt = .now
            saveError = nil
            return true
        }
        saveError = store.errorMessage ?? "This note couldn't be saved."
        return false
    }

    /// Called as the note editor closes. Saves the note, or removes a stored
    /// note that was emptied. Returns false, with the reason in `saveError`,
    /// when neither worked.
    @discardableResult
    func finishNote() -> Bool {
        autosaveTask?.cancel()
        guard case .note(let note) = editor, let store else { return false }
        guard isEmptyNote else { return saveNote() }
        guard store.database.notes.contains(where: { $0.id == note.id }) else { return true }
        let itemID = "note.\(note.id)"
        let removed = store.update { database in
            database.notes.removeAll { $0.id == note.id }
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
