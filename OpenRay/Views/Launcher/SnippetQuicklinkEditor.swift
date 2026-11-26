import AppKit
import SwiftUI

/// The snippet and quicklink form inside `InlineEditorView`.
struct FormEditorBody: View {
    let model: LauncherModel
    @Bindable var draft: EditorDraft
    @FocusState private var focus: Field?
    @State private var selection: TextSelection?

    enum Field: Hashable { case name, keyword, content, tags }

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
                        "Link",
                        help: "Any URL, deeplink, or file or folder path. Insert {argument name=\"…\"} or {query} where a value goes.",
                        error: draft.contentError ?? draft.placeholderNotes.first
                    ) {
                        HStack(spacing: 8) {
                            TextField(
                                "", text: $draft.content,
                                prompt: Text("https://duckduckgo.com/?q={query}").foregroundStyle(OR.Color.text3)
                            )
                            .textFieldStyle(.plain).font(OR.Font.mono).focused($focus, equals: .content)
                            .accessibilityLabel("Link").accessibilityHint(draft.contentError ?? "")
                            .accessibilityIdentifier("editor.content")
                            if !draft.content.contains("{query}") && !draft.content.contains("{argument") {
                                Button { draft.content += "{query}" } label: { PlaceholderChip(text: "{query}") }
                                    .buttonStyle(.plain).help("Insert {query}")
                            }
                            placeholderMenu(for: .quicklink) { draft.content += $0 }
                        }
                        .fieldBox(focused: focus == .content, invalid: draft.contentError != nil)
                    }
                }
                FieldGroup("Tags", help: "Separate tags with commas.", error: draft.tagsError) {
                    TextField("", text: $draft.tags, prompt: Text("work, email").foregroundStyle(OR.Color.text3))
                        .textFieldStyle(.plain).font(OR.Font.body).focused($focus, equals: .tags)
                        .fieldBox(focused: focus == .tags, invalid: draft.tagsError != nil)
                        .accessibilityLabel("Tags, optional").accessibilityHint(draft.tagsError ?? "")
                        .accessibilityIdentifier("editor.tags")
                }
                if draft.isQuicklink {
                    FieldGroup("Open With", help: "The app the link opens in.") {
                        Picker("Open With", selection: openWithBinding) {
                            Text("Default App").tag(String?.none)
                            if let current = draft.openWith,
                                !model.applications.applications.contains(where: { $0.bundleIdentifier == current.bundleIdentifier })
                            {
                                Text(current.name).tag(String?.some(current.bundleIdentifier))
                            }
                            ForEach(model.applications.applications.filter { $0.bundleIdentifier != nil }) { app in
                                Text(app.name).tag(app.bundleIdentifier)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu)
                        .accessibilityIdentifier("editor.openWith")
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
                            if let error = draft.contentError ?? draft.placeholderNotes.first {
                                Label(error, systemImage: "exclamationmark.triangle").labelStyle(TightLabelStyle())
                                    .font(OR.Font.callout).foregroundStyle(OR.Color.danger)
                            } else {
                                Text("Insert").font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                                ForEach(["{clipboard}", "{cursor}", "{date}", "{time}"], id: \.self) { token in
                                    Button { insert(token) } label: { PlaceholderChip(text: token) }
                                        .buttonStyle(.plain).help("Insert \(token) at the caret")
                                }
                                placeholderMenu(for: .snippet) { insert($0) }
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

    /// Every placeholder this kind of item honors, for the ones without a chip.
    private func placeholderMenu(for context: PlaceholderContext, insert: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(Placeholder.Kind.suggested(in: context), id: \.self) { kind in
                Button(kind.title) { insert(kind.insertionText) }
            }
        } label: {
            PlaceholderChip(text: "More…")
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .help("Insert a placeholder")
        .accessibilityLabel("Insert a placeholder")
    }

    /// The picker's tag is the bundle identifier; nil means the default app.
    private var openWithBinding: Binding<String?> {
        Binding(
            get: { draft.openWith?.bundleIdentifier },
            set: { identifier in
                guard let identifier else {
                    draft.openWith = nil
                    return
                }
                if let app = model.applications.applications.first(where: { $0.bundleIdentifier == identifier }) {
                    draft.openWith = QuicklinkApplication(bundleIdentifier: identifier, name: app.name)
                }
            })
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
