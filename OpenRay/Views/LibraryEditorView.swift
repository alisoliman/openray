import SwiftUI

struct LibraryEditorView: View {
    let context: LibraryEditor
    let model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var keyword: String
    @State private var content: String
    @State private var argument: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(context: LibraryEditor, model: LauncherModel) {
        self.context = context
        self.model = model
        switch context {
        case .quicklink(let item):
            _name = State(initialValue: item.name)
            _keyword = State(initialValue: item.keyword)
            _content = State(initialValue: item.template)
            _argument = State(initialValue: "")
        case .snippet(let item):
            _name = State(initialValue: item.name)
            _keyword = State(initialValue: item.keyword)
            _content = State(initialValue: item.content)
            _argument = State(initialValue: "")
        case .note(let item):
            _name = State(initialValue: item.title)
            _keyword = State(initialValue: "")
            _content = State(initialValue: item.content)
            _argument = State(initialValue: "")
        case .quicklinkQuery(let item, let query):
            _name = State(initialValue: item.name)
            _keyword = State(initialValue: item.keyword)
            _content = State(initialValue: item.template)
            _argument = State(initialValue: query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                OpenRayMark()
                Text(title).font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            if case .quicklinkQuery = context {
                Text(content).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                TextField("Search term", text: $argument).textFieldStyle(.roundedBorder)
                    .focused($nameFocused).onSubmit(save).accessibilityIdentifier("editor.argument")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Name").font(.system(size: 12, weight: .medium))
                    TextField("Give it a memorable name", text: $name).textFieldStyle(.roundedBorder)
                        .focused($nameFocused).accessibilityIdentifier("editor.name")
                }
                if case .quicklink = context {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Link").font(.system(size: 12, weight: .medium))
                        TextField("https://example.com/search?q={query}", text: $content).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("editor.content")
                        Text("Use {query} for a search term, or enter an absolute file/folder path.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Text").font(.system(size: 12, weight: .medium))
                        TextEditor(text: $content).font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(8).frame(height: 180).background(
                                .primary.opacity(0.04), in: .rect(cornerRadius: 7)
                            )
                            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.1)) }
                            .accessibilityLabel("Content").accessibilityIdentifier("editor.content")
                    }
                }
                if showsKeyword {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Keyword (optional)").font(.system(size: 12, weight: .medium))
                        TextField(isSnippet ? ";email" : "web", text: $keyword).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("editor.keyword")
                        Text(
                            isSnippet
                                ? "Type the keyword to expand when enabled in Settings. {date} and {time} are supported in text."
                                : "Type this keyword followed by a search term in the launcher."
                        )
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Label("Saved only on this Mac", systemImage: "lock").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isQuery ? "Open Link" : "Save", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut("s").accessibilityIdentifier("editor.save")
            }
        }.padding(26).frame(width: 560).tint(RayStyle.accent).defaultFocus($nameFocused, true)
    }

    private var isSnippet: Bool { if case .snippet = context { true } else { false } }
    private var isQuery: Bool { if case .quicklinkQuery = context { true } else { false } }
    private var showsKeyword: Bool { if case .note = context { false } else { true } }
    private var title: String {
        switch context {
        case .quicklink: "Quicklink"
        case .snippet: "Snippet"
        case .note: "Note"
        case .quicklinkQuery: name
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: Bool
        switch context {
        case .quicklink(var item):
            item.name = trimmedName
            item.keyword = trimmedKeyword
            item.template = content
            saved = model.store.save(item)
        case .snippet(var item):
            item.name = trimmedName
            item.keyword = trimmedKeyword
            item.content = content
            saved = model.store.save(item)
        case .note(var item):
            item.title = trimmedName
            item.content = content
            saved = model.store.save(item)
        case .quicklinkQuery(let item, _):
            do { _ = try item.resolvedURL(query: argument) } catch {
                self.error = error.localizedDescription
                return
            }
            dismiss()
            model.openQuicklink(item, query: argument)
            return
        }
        if saved {
            dismiss()
        } else {
            error = model.store.errorMessage ?? "This library is read-only. Your original data has been preserved."
        }
    }
}
