import AppKit

/// Owns the Notes window and its model for the app's library. Providers, the menu bar and the
/// inline editor all reach the one window through here.
@MainActor
final class NotesCenter {
    static let shared = NotesCenter()

    /// The app's launcher, set at launch, for the inline editor's “Open in Notes Window”.
    weak var launcher: LauncherModel?
    private var current: NotesWindowModel?
    private var presenter: (any NotesWindowPresenting)?
    private let makeModel: @MainActor (LibraryStore) -> NotesWindowModel
    private let makePresenter: @MainActor (NotesWindowModel) -> any NotesWindowPresenting

    init(
        makeModel: @escaping @MainActor (LibraryStore) -> NotesWindowModel = {
            NotesWindowModel(store: $0, assets: NoteAssetStore(libraryURL: $0.fileURL))
        },
        makePresenter: (@MainActor (NotesWindowModel) -> any NotesWindowPresenting)? = nil
    ) {
        self.makeModel = makeModel
        self.makePresenter = makePresenter ?? { model in NotesWindowController(model: model) }
    }

    /// The window model for a library, created on first use.
    func model(for store: LibraryStore) -> NotesWindowModel {
        if let current, current.store === store { return current }
        let model = makeModel(store)
        let presenter = makePresenter(model)
        if let controller = presenter as? NotesWindowController {
            controller.appearance = { [weak self] in
                guard let launcher = self?.launcher else { return nil }
                return Self.appearance(for: launcher.store.database.preferences.appearance)
            }
        }
        model.presenter = presenter
        // The launcher's inline editor, when it shows the same note, follows saves made here, and
        // its words keep their images through a purge.
        model.onSaved = { [weak self] id in
            guard let draft = self?.launcher?.draft, draft.noteID == id else { return }
            draft.refreshCleanFields()
        }
        model.externalTexts = { [weak self] in
            guard let draft = self?.launcher?.draft, draft.isNote else { return [] }
            return [draft.content]
        }
        self.presenter = presenter
        current = model
        return model
    }

    var isWindowVisible: Bool { current?.isWindowVisible ?? false }

    /// Before the app quits: saves typed text, or writes what can't be saved to a recovery file.
    @discardableResult
    func prepareForTermination() -> URL? {
        current?.prepareForTermination()
    }

    /// Moves a note from the inline editor to the floating window: the editor closes, the
    /// launcher hides, and the window opens on the note.
    func openInWindow(noteID: UUID, store: LibraryStore) {
        let model = model(for: store)
        if let launcher, launcher.editor != nil { launcher.goBack() }
        launcher?.panel?.dismiss(restoreFocus: false)
        model.show(noteID: noteID)
    }

    static func appearance(for choice: AppAppearance) -> NSAppearance? {
        switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
