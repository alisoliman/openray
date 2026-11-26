import SwiftUI

/// The Notes window's launcher commands: toggle, open, create and search, Recently Deleted,
/// and the menu bar toggle.
@MainActor
final class NotesCommandProvider: CommandProvider, MenuBarExtraProviding {
    nonisolated static let registration = CommandProviderRegistration(id: "notes", bindablePrefixes: ["notes."]) {
        NotesCommandProvider()
    }

    static let toggleID = "notes.toggle"
    static let openID = "notes.open"
    static let createID = "notes.create"
    static let searchID = "notes.search"
    static let recentlyDeletedID = "notes.recentlyDeleted"
    static let menuBarID = "notes.menuBar"

    static let deletedScope = ProvidedScope(
        id: "notes.deleted", provider: "notes", title: "Recently Deleted Notes", symbol: "trash", kind: .note,
        placeholder: "Search deleted notes", summary: "Notes you deleted in the last 60 days",
        shortTitle: "Deleted Notes", itemNoun: "deleted note", showsPreview: true)

    var id: String { Self.registration.id }
    let center: NotesCenter

    init() {
        center = .shared
    }

    init(center: NotesCenter) {
        self.center = center
    }

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.toggleID, title: "Toggle Notes Window", subtitle: "Show or hide the floating Notes window",
                kind: .note, symbol: "macwindow", keywords: ["notes", "floating", "scratchpad", "show", "hide"],
                mode: .noView),
            CommandDescriptor(
                id: Self.openID, title: "Open Notes", subtitle: "The floating Notes window, on your last note",
                kind: .note, symbol: "note.text", keywords: ["notes", "window", "scratchpad"], mode: .noView),
            CommandDescriptor(
                id: Self.createID, title: "Create Note", subtitle: "A new note in the Notes window", kind: .note,
                symbol: "square.and.pencil", keywords: ["new note", "write", "capture", "jot"], mode: .noView),
            CommandDescriptor(
                id: Self.searchID, title: "Search Notes", subtitle: "Find notes by title and text", kind: .note,
                symbol: "magnifyingglass", keywords: ["notes", "find"], mode: .view(.notes)),
            CommandDescriptor(
                id: Self.recentlyDeletedID, title: "Recently Deleted Notes",
                subtitle: "Restore notes deleted in the last 60 days", kind: .note, symbol: "trash",
                keywords: ["notes", "trash", "restore", "undelete", "bin"], mode: .view(.provided(Self.deletedScope))),
            CommandDescriptor(
                id: Self.menuBarID, title: "Notes in Menu Bar",
                subtitle: "A menu bar button that shows or hides the Notes window", kind: .note, symbol: "menubar.rectangle",
                keywords: ["notes", "menu bar", "toggle", "status"], mode: .menuBar, badge: "Menu Bar"),
        ]
    }

    // MARK: Running

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        let notes = center.model(for: model.store)
        switch ref.id {
        case Self.toggleID:
            model.store.recordUse(of: item.id)
            // From the launcher the window can't have focus, so a visible one hides; from a
            // hotkey, one that's behind other apps comes forward instead.
            if notes.isWindowKey || (notes.isWindowVisible && model.panel?.isVisible == true) {
                notes.hide()
            } else {
                model.panel?.dismiss(restoreFocus: false)
                if !notes.show() { reportUnavailable(in: model) }
            }
        case Self.openID:
            model.store.recordUse(of: item.id)
            model.panel?.dismiss(restoreFocus: false)
            if !notes.show() { reportUnavailable(in: model) }
        case Self.createID:
            model.store.recordUse(of: item.id)
            model.panel?.dismiss(restoreFocus: false)
            if !notes.showNewNote() { reportUnavailable(in: model) }
        case Self.menuBarID:
            guard let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) else { return }
            MenuBarExtras.toggle(command, provider: self, in: model)
        default:
            // A row in Recently Deleted: restore it and open it in the window.
            guard ref.payload == "deleted", let noteID = UUID(uuidString: ref.id) else { return }
            guard notes.restore(noteID) else {
                model.feedback = .warning(notes.notice?.text ?? "This note couldn't be restored.")
                return
            }
            model.panel?.dismiss(restoreFocus: false)
            if !notes.show(noteID: noteID) {
                model.toast("Restored “\(item.title.truncatedForFeedback)”")
            }
        }
    }

    private func reportUnavailable(in model: LauncherModel) {
        model.feedback = .info("The Notes window doesn't open in tests or isolated verification mode.")
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == "deleted" ? "Restore Note" : nil
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.payload == "deleted" ? "arrow.uturn.backward" : nil
    }

    // MARK: Recently Deleted

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.deletedScope.id else { return [] }
        let notes = center.model(for: model.store)
        let now = notes.now()
        // Notes past their 60 days are gone, even if the Notes window hasn't opened to purge them.
        let expired = Set(NoteCollection.expired(model.store.database.notes, now: now).map(\.id))
        if !expired.isEmpty { Task { @MainActor in notes.purgeExpired() } }
        return NoteCollection.deleted(model.store.database.notes).filter { !expired.contains($0.id) }.map { note in
            let days = note.expiresAt.map { max(0, Int(ceil($0.timeIntervalSince(now) / 86_400))) } ?? 0
            let deleted = note.deletedAt?.formatted(.relative(presentation: .named)) ?? ""
            return LauncherItem(
                id: "notes.deleted.\(note.id)", title: note.title.isEmpty ? "Untitled Note" : note.title,
                subtitle: "Deleted \(deleted) · removed in \(days) day\(days == 1 ? "" : "s")", symbol: "note.text",
                kind: .note, badge: "Deleted", keywords: note.content,
                action: .provided(
                    ProvidedRef(
                        provider: id, id: note.id.uuidString, payload: "deleted", copyText: note.content,
                        primaryTitle: "Restore Note", traits: [.delete, .paste])))
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel) -> ProvidedEmptyState? {
        guard scope.id == Self.deletedScope.id, query.isEmpty else { return nil }
        return ProvidedEmptyState(
            title: "Recently Deleted is empty", detail: "Notes you delete stay here for 60 days, then they're removed.",
            symbol: "trash")
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard ref.payload == "deleted", let note = model.store.database.notes.first(where: { $0.id.uuidString == ref.id })
        else { return nil }
        return ProvidedPreview(
            content: AnyView(
                ScrollView {
                    Text(note.content).font(OR.Font.reading).foregroundStyle(OR.Color.text)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }),
            metadata: [
                ("Deleted", note.deletedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"),
                ("Removed", note.expiresAt?.formatted(date: .abbreviated, time: .omitted) ?? "—"),
                ("Words", note.wordCount.formatted()),
            ])
    }

    func itemNoun(for ref: ProvidedRef) -> String { ref.payload == "deleted" ? "Note Now" : "Note" }

    func deletion(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedDeletion? {
        guard ref.payload == "deleted", let noteID = UUID(uuidString: ref.id) else { return nil }
        let notes = center.model(for: model.store)
        return .store { [weak model] in
            let removed = notes.deletePermanently(noteID)
            if !removed { model?.feedback = .error(notes.store.errorMessage ?? "This note couldn't be deleted.") }
            return removed
        }
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        if ref.id == Self.menuBarID, let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) {
            return [MenuBarExtras.toggleAction(command, provider: self, in: model)]
        }
        guard ref.payload == "deleted" else { return [] }
        let notes = center.model(for: model.store)
        let count = notes.deletedNotes.count
        return [
            ActionEntry(
                id: "notes.copy", title: "Copy Text", symbol: "doc.on.doc", shortcut: .command("C", shift: true), key: "c",
                modifiers: [.command, .shift], group: .item
            ) { [weak model] in
                guard let model, let text = ref.copyText else { return }
                model.copy(text, label: item.title)
            },
            ActionEntry(
                id: "notes.empty", title: "Empty Recently Deleted…", symbol: "trash.slash", group: .organize,
                isDestructive: true
            ) { [weak model] in
                guard let model else { return }
                // Destructive: Return approves only once the prompt has been on screen, and a held
                // Return never does.
                let question = CommandConfirmation(
                    question: "Delete all \(count) notes in Recently Deleted?", detail: "You can't undo this.",
                    confirmTitle: "Empty", symbol: "trash", isDestructive: true)
                model.presentConfirmation(.provided(
                    ProvidedConfirmation(id: "notes.empty", question) { [weak model] in
                        if notes.emptyRecentlyDeleted() {
                            model?.toast("Recently Deleted is empty")
                        } else {
                            model?.feedback = .error(notes.notice?.text ?? "Recently Deleted couldn't be emptied.")
                        }
                    }))
            },
        ]
    }

    // MARK: Menu bar

    func menuBarExtra(for command: CommandDescriptor, in model: LauncherModel) -> MenuBarExtraContent? {
        guard command.id == Self.menuBarID else { return nil }
        let center = center
        let store = model.store
        return MenuBarExtraContent(
            title: nil, symbol: "note.text", accessibilityLabel: "Show or hide Notes",
            click: { center.model(for: store).toggle() })
    }
}
