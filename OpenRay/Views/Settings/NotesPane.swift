import AppKit
import SwiftUI

extension SettingsPane {
    static let notes = SettingsPane(
        id: "notes", title: "Notes",
        subtitle: "The floating Notes window, pinned notes and Recently Deleted.",
        kind: .note, symbol: "note.text",
        keywords: "notes floating window markdown pin pinned recently deleted trash images menu bar toggle"
    ) { model, navigation in AnyView(NotesPane(model: model, navigation: navigation)) }
}

struct NotesPane: View {
    @Bindable var model: LauncherModel
    @Bindable var navigation: SettingsNavigation
    @State private var confirmsEmpty = false

    private var notes: [QuickNote] { model.store.database.notes }

    var body: some View {
        SettingsPaneScaffold(pane: .notes) {
            Section("Notes window") {
                Toggle(isOn: menuBarBinding) {
                    SettingRowLabel(
                        title: "Notes button in the menu bar", detail: "A click shows or hides the floating Notes window.")
                }
                .settingsSwitch()
                LabeledContent {
                    Button("Assign…") {
                        navigation.focusCommandID = NotesCommandProvider.toggleID
                        navigation.pane = .shortcuts
                    }
                } label: {
                    SettingRowLabel(title: "Hotkey", detail: "Give Toggle Notes Window a shortcut to open notes from anywhere.")
                }
            }
            Section("Keyboard") {
                IconRow("⌘P browses and searches notes. ⌘[ and ⌘] go back and forward.", symbol: "magnifyingglass")
                IconRow("⇧⌘P pins a note; ⌘1 – ⌘9 and ⌘0 open pinned notes.", symbol: "pin")
                IconRow("Type / for headings, lists, tasks, quotes, code and images.", symbol: "slash.circle")
                IconRow("⌘↩ checks the task on the current line. ⌘B, ⌘I, ⌘E and ⌘L format.", symbol: "checklist")
                IconRow("Paste or drop an image to add it to the note.", symbol: "photo")
            }
            Section {
                LabeledContent {
                    Button("Empty…", role: .destructive) { confirmsEmpty = true }
                        .disabled(NoteCollection.deleted(notes).isEmpty)
                } label: {
                    let count = NoteCollection.deleted(notes).count
                    SettingRowLabel(
                        title: "Recently Deleted",
                        detail: "\(count) note\(count == 1 ? "" : "s"). Deleted notes are kept for 60 days, then removed.")
                }
            } header: {
                Text("Recently Deleted")
            }
            Section("Storage") {
                LabeledContent {
                    Button("Show in Finder") { revealAssets() }
                } label: {
                    SettingRowLabel(
                        title: "Images",
                        detail: "Images in notes are saved in a NoteAssets folder next to your library. Exports link to them.")
                }
            }
        }
        .confirmationDialog(
            "Delete every note in Recently Deleted?", isPresented: $confirmsEmpty, titleVisibility: .visible
        ) {
            Button("Empty Recently Deleted", role: .destructive) {
                NotesCenter.shared.model(for: model.store).emptyRecentlyDeleted()
            }
        } message: {
            Text("You can't undo this.")
        }
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { MenuBarExtras.isShown(NotesCommandProvider.menuBarID, default: false, in: model.store.database) },
            set: { MenuBarExtras.setShown($0, commandID: NotesCommandProvider.menuBarID, in: model.store) })
    }

    private func revealAssets() {
        guard (try? SideEffectGuard.check("showing Finder")) != nil else { return }
        let assets = NoteAssetStore(libraryURL: model.store.fileURL)
        try? FileManager.default.createDirectory(at: assets.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([assets.directory])
    }
}
