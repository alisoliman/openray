import AppKit
import SwiftUI

/// Editors open inside the panel. The field becomes a breadcrumb, Esc cancels
/// (or finishes a note), and ⌘S saves.
struct InlineEditorView: View {
    @Bindable var model: LauncherModel
    @Bindable var draft: EditorDraft

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                kind: draft.editor.section.kind, symbol: draft.editor.section.tileSymbol,
                scope: draft.editor.section.title, title: draft.title, onScope: { model.goBack() })
            Hairline()
            Group {
                if draft.isNote {
                    NoteEditorBody(draft: draft, focusRequest: model.focusRequest)
                } else {
                    FormEditorBody(model: model, draft: draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .background {
            ZStack {
                Button("Save") { model.saveEditor() }.keyboardShortcut("s")
                if draft.isQuicklink {
                    Button("Test") { testQuicklink() }.keyboardShortcut("t")
                }
                if draft.isNote {
                    Button("Paste") { pasteNote() }.keyboardShortcut(.return, modifiers: .command)
                }
            }
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var bar: some View {
        ActionBar(
            feedback: model.feedback ?? draft.saveError.map { .error($0) }, confirmation: model.confirmation,
            context: { context },
            actions: { actions },
            onCancelConfirmation: { model.confirmation = nil },
            onConfirm: { if let confirmation = model.confirmation { model.confirm(confirmation) } })
    }

    @ViewBuilder private var context: some View {
        if draft.isNote {
            if draft.savedAt != nil && !draft.isEmptyNote {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(OR.Color.success)
                    .accessibilityHidden(true)
                Text("Saved")
            } else {
                KindTile(kind: .note, size: 18)
                Text(draft.isEmptyNote ? "Notes save as you type" : "Saving…")
            }
        } else {
            KindTile(kind: draft.editor.section.kind, symbol: draft.editor.section.tileSymbol, size: 18)
            if draft.isNew {
                Text("Unsaved \(draft.editor.section.itemNoun)")
            } else {
                Text(draft.isDirty ? "Edited · not saved yet" : "No changes")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if draft.isNote {
            if !draft.isEmptyNote {
                ActionBarButton(title: model.canPasteDirectly || !model.clipboard.usesGeneralPasteboard
                    ? "Paste to \(model.targetAppName)" : "Copy · ⌘V in \(model.targetAppName)",
                    keys: ["⌘", "↩"], style: .ghost, action: pasteNote)
                ActionBarDivider()
            }
            ActionBarButton(title: "Done", keys: ["esc"]) { model.goBack() }
        } else {
            if draft.isQuicklink {
                ActionBarButton(title: "Test", keys: ["⌘", "T"], style: .ghost, action: testQuicklink)
                    .disabled(!draft.quicklinkPreview.valid)
                ActionBarDivider()
            }
            ActionBarButton(title: "Cancel", keys: ["esc"], style: .ghost) { model.goBack() }
            ActionBarButton(title: "Save", keys: ["⌘", "S"], style: .accent) { model.saveEditor() }
                .accessibilityIdentifier("editor.save")
        }
    }

    private func testQuicklink() {
        let link = Quicklink(name: draft.name, template: draft.content, keyword: draft.keyword)
        if let url = try? link.resolvedURL(query: link.needsQuery ? "swift concurrency" : "") {
            NSWorkspace.shared.open(url)
        }
    }

    private func pasteNote() {
        draft.saveNote()
        model.paste(draft.content, label: draft.title)
    }
}

// MARK: - Snippet & quicklink

private struct FormEditorBody: View {
    let model: LauncherModel
    @Bindable var draft: EditorDraft
    @FocusState private var focus: Field?
    @State private var selection: TextSelection?

    enum Field: Hashable { case name, keyword, content }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                FieldGroup("Name", error: draft.nameError) {
                    TextField(
                        "", text: $draft.name,
                        prompt: Text(draft.isSnippet ? "Email signature" : "Search the Web").foregroundStyle(OR.Color.text3)
                    )
                    .textFieldStyle(.plain).font(OR.Font.body).focused($focus, equals: .name)
                    .fieldBox(focused: focus == .name, invalid: draft.nameError != nil)
                    .accessibilityLabel("Name").accessibilityHint(draft.nameError ?? "")
                    .accessibilityIdentifier("editor.name")
                }
                if draft.isQuicklink {
                    FieldGroup(
                        "Link", help: "Insert {query} where the search term goes, or use a file or folder path.",
                        error: draft.contentError
                    ) {
                        HStack(spacing: 8) {
                            TextField(
                                "", text: $draft.content,
                                prompt: Text("https://duckduckgo.com/?q={query}").foregroundStyle(OR.Color.text3)
                            )
                            .textFieldStyle(.plain).font(OR.Font.mono).focused($focus, equals: .content)
                            .accessibilityLabel("Link").accessibilityHint(draft.contentError ?? "")
                            .accessibilityIdentifier("editor.content")
                            if !draft.content.contains("{query}") {
                                Button { draft.content += "{query}" } label: { PlaceholderChip(text: "{query}") }
                                    .buttonStyle(.plain).help("Insert {query}")
                            }
                        }
                        .fieldBox(focused: focus == .content, invalid: draft.contentError != nil)
                    }
                }
                FieldGroup(
                    "Keyword", help: keywordHelp, error: draft.keywordError
                ) {
                    TextField("", text: $draft.keyword, prompt: Text(draft.isSnippet ? ";sig" : "web").foregroundStyle(OR.Color.text3))
                        .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                        .focused($focus, equals: .keyword)
                        .fieldBox(focused: focus == .keyword, invalid: draft.keywordError != nil)
                        .accessibilityLabel("Keyword, optional").accessibilityHint(draft.keywordError ?? "")
                        .accessibilityIdentifier("editor.keyword")
                }
                if draft.isSnippet {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Text").font(.system(size: 12, weight: .semibold)).foregroundStyle(OR.Color.text)
                        TextEditor(text: $draft.content, selection: $selection)
                            .font(OR.Font.body).scrollContentBackground(.hidden)
                            .focused($focus, equals: .content)
                            // Cancels NSTextView's 5 pt line padding, so text starts where Name and Keyword do.
                            .padding(.vertical, 9).padding(.horizontal, -5)
                            .fieldBox(focused: focus == .content, invalid: draft.contentError != nil, minHeight: 120)
                            .frame(maxHeight: .infinity)
                            .accessibilityLabel("Snippet text").accessibilityHint(draft.contentError ?? "")
                            .accessibilityIdentifier("editor.content")
                        HStack(spacing: 6) {
                            if let error = draft.contentError {
                                Label(error, systemImage: "exclamationmark.triangle").labelStyle(TightLabelStyle())
                                    .font(OR.Font.callout).foregroundStyle(OR.Color.danger)
                            } else {
                                Text("Insert").font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                                ForEach(["{date}", "{time}"], id: \.self) { token in
                                    Button { insert(token) } label: { PlaceholderChip(text: token) }
                                        .buttonStyle(.plain).help("Insert \(token) at the caret")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            side
                .frame(width: 270)
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Hairline(vertical: true) }
        }
        .onAppear {
            DispatchQueue.main.async { focus = draft.isNew || draft.name.isEmpty ? .name : .content }
        }
        // A blocked save sends the keyboard to the first field that needs fixing, in form order.
        .onChange(of: draft.invalidFocusRequest) { focus = firstInvalidField }
    }

    private var firstInvalidField: Field {
        if draft.nameError != nil { return .name }
        if draft.isQuicklink && draft.contentError != nil { return .content }
        if draft.keywordError != nil { return .keyword }
        return .content
    }

    private var keywordHelp: String {
        draft.isSnippet
            ? "Type it in any app to expand. Unique across aliases and quicklink keywords."
            : "Type it and a space in Everything to search with this link."
    }

    @ViewBuilder private var side: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview").font(.system(size: 12, weight: .semibold)).foregroundStyle(OR.Color.text2)
            if draft.isSnippet {
                ScrollView {
                    Text(draft.content.isEmpty ? "Your text appears here, with {date} and {time} filled in." : draft.snippetPreview)
                        .font(.system(size: 12.5)).lineSpacing(4)
                        .foregroundStyle(draft.content.isEmpty ? OR.Color.text3 : OR.Color.text)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
                Text("Expansion").font(.system(size: 12, weight: .semibold)).foregroundStyle(OR.Color.text2)
                    .padding(.top, 8)
                // While expansion is off for every snippet, the switch shows that (off) rather than the stored choice.
                Toggle(
                    isOn: Binding(
                        get: { expansionEnabled && draft.expandsKeyword },
                        set: { draft.expandsKeyword = $0 })
                ) {
                    Text(draft.keyword.isEmpty ? "Expand as I type" : "Expand “\(draft.keyword)” as I type")
                        .font(.system(size: 12.5)).foregroundStyle(OR.Color.text).lineLimit(1)
                }
                .toggleStyle(.orSwitch)
                .disabled(draft.keyword.isEmpty || !expansionEnabled)
                expansionStatus
            } else {
                let preview = draft.quicklinkPreview
                Text(preview.url).font(OR.Font.mono).lineLimit(4)
                    .foregroundStyle(preview.valid ? OR.Color.text : OR.Color.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
                Text(
                    draft.content.contains("{query}")
                        ? "Shown with the sample search “swift concurrency”. Test opens it in \(model.defaultBrowserName)."
                        : "Opens directly in \(opener(valid: preview.valid))."
                )
                .font(OR.Font.callout).foregroundStyle(OR.Color.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private var expansionEnabled: Bool { model.store.database.preferences.snippetExpansionEnabled }

    /// Why the switch is in its state, with the step that changes it. Accessibility comes
    /// first, as in Settings, because expansion can't run without it.
    @ViewBuilder private var expansionStatus: some View {
        if !model.accessibilityAllowed {
            expansionNote("Needs Accessibility, which is off.")
            Button("Enable…") {
                model.windows.requestPermission()
                SystemSettingsLink.open(.accessibility)
            }
            .buttonStyle(.orSecondary)
        } else if !expansionEnabled {
            // Never turned on for you: snippets saved before 2.0 would start expanding without a yes.
            expansionNote("Keyword expansion is off for all snippets.")
            Button("Turn On", action: turnOnExpansion).buttonStyle(.orSecondary)
                .accessibilityHint("Turns on keyword expansion for all snippets")
        } else {
            expansionNote("Needs Accessibility, which is on. Skipped during Secure Input and in excluded apps.")
        }
    }

    private func expansionNote(_ text: String) -> some View {
        Text(text).font(OR.Font.callout).lineSpacing(2).foregroundStyle(OR.Color.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func turnOnExpansion() {
        if model.store.update({ $0.preferences.snippetExpansionEnabled = true }) {
            model.applyPreferences()
            model.toast("Keyword expansion is on")
        } else {
            model.feedback = .error(model.store.errorMessage ?? "Keyword expansion couldn't be turned on.")
        }
    }

    /// Folders open in Finder and files in their default app. Until the link resolves, it names the browser.
    private func opener(valid: Bool) -> String {
        guard valid else { return model.defaultBrowserName }
        return model.openerName(for: Quicklink(name: draft.name, template: draft.content, keyword: draft.keyword))
    }

    private func insert(_ token: String) {
        if let selection, case .selection(let range) = selection.indices,
            range.lowerBound >= draft.content.startIndex, range.upperBound <= draft.content.endIndex
        {
            draft.content.replaceSubrange(range, with: token)
        } else {
            draft.content += token
        }
        focus = .content
    }
}

// MARK: - Note

/// Full-width writing. The title is optional: the first line stands in for it.
private struct NoteEditorBody: View {
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
            Text(meta).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
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

    private var meta: String {
        let words = draft.content.split { $0.isWhitespace || $0.isNewline }.count
        let count = "\(words.formatted()) word\(words == 1 ? "" : "s")"
        guard let saved = draft.savedAt else { return draft.isNew ? "New note · \(count)" : count }
        let elapsed = Date().timeIntervalSince(saved)
        let when = elapsed < 60 ? "just now" : saved.formatted(.relative(presentation: .named))
        return "Edited \(when) · \(count)"
    }
}
