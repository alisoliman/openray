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
