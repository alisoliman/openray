import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsPane {
    static let library = SettingsPane(
        id: "library", title: "Library",
        subtitle: "Your notes, snippets, quicklinks and history, stored on this Mac.",
        kind: .system, symbol: "books.vertical",
        keywords: "reveal finder export data location backup json"
    ) { model, _ in AnyView(LibraryPane(model: model)) }
}

struct LibraryPane: View {
    let model: LauncherModel

    var body: some View {
        let database = model.store.database
        SettingsPaneScaffold(pane: .library) {
            Section("Contents") {
                LabeledContent("Notes", value: database.notes.count.formatted())
                LabeledContent("Snippets", value: database.snippets.count.formatted())
                LabeledContent("Quicklinks", value: database.quicklinks.count.formatted())
                LabeledContent("Favorites", value: database.favoriteIDs.count.formatted())
                LabeledContent("Clipboard entries", value: database.clipboard.count.formatted())
            }
            Section {
                if let url = model.store.fileURL {
                    LabeledContent {
                        HStack {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                            Button("Export…") { export(url) }
                                .disabled(!FileManager.default.fileExists(atPath: url.path))
                        }
                    } label: {
                        SettingRowLabel(title: "Location", detail: LauncherModel.shortenedPath(url.deletingLastPathComponent()))
                    }
                } else {
                    Label("This instance uses a temporary, in-memory library.", systemImage: "memorychip")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Data")
            } footer: {
                Text("library.json and the ClipboardImages folder are readable only by your account, but OpenRay doesn't encrypt them. Export saves library.json only, so back up both together.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func export(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenRay Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Exporting onto the live library would only replace it with itself.
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath()
        else { return }
        // An atomic write never leaves a half-written or deleted file at the destination.
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
