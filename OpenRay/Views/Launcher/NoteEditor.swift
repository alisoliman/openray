import SwiftUI

/// Full-width writing. The title is optional: the first line stands in for it.
struct NoteEditorBody: View {
    @Bindable var draft: EditorDraft
    var focusRequest: Int
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, body }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $draft.name, prompt: Text("Title").foregroundStyle(OR.Color.text3))
                .textFieldStyle(.plain).font(OR.Font.display).tracking(-0.4)
                .foregroundStyle(OR.Color.text)
                .focused($focus, equals: .title)
                .onSubmit { focus = .body }
                .accessibilityLabel("Note title").accessibilityIdentifier("editor.name")
            HStack(spacing: 8) {
                Text(meta).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                Spacer(minLength: 8)
                // The floating window has Markdown, pins and history; ⌘O moves the note there.
                Button(action: openInNotesWindow) {
                    Label("Open in Notes Window", systemImage: "macwindow").labelStyle(TightLabelStyle())
                }
                .buttonStyle(.orGhost)
                .keyboardShortcut("o")
                .help("Open in Notes Window (⌘O)")
                .accessibilityIdentifier("editor.openInNotesWindow")
            }
            TextEditor(text: $draft.content)
                .font(OR.Font.reading).lineSpacing(6)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .padding(.horizontal, -5)
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Note").accessibilityIdentifier("editor.content")
        }
        .padding(.horizontal, 64).padding(.top, 22).padding(.bottom, 12)
        .onAppear {
            DispatchQueue.main.async { focus = draft.name.isEmpty && draft.content.isEmpty ? .title : .body }
        }
    }

    /// Saves the note, closes this editor and shows the note in the floating Notes window.
    private func openInNotesWindow() {
        guard case .note(let note) = draft.editor, !draft.isEmptyNote, draft.saveNote(),
            let store = NotesCenter.shared.launcher?.store
        else { return }
        NotesCenter.shared.openInWindow(noteID: note.id, store: store)
    }

    private var meta: String {
        let words = draft.content.split { $0.isWhitespace || $0.isNewline }.count
        let count = "\(words.formatted()) word\(words == 1 ? "" : "s")"
        guard let saved = draft.savedAt else { return draft.isNew ? "New note · \(count)" : count }
        let elapsed = Date().timeIntervalSince(saved)
        let when = elapsed < 60 ? "just now" : saved.formatted(.relative(presentation: .named))
        return "Edited \(when) · \(count)"
    }
}
