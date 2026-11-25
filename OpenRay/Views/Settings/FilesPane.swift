import AppKit
import SwiftUI

extension SettingsPane {
    static let files = SettingsPane(
        id: "files", title: "Files",
        subtitle: "Where Files looks, using your existing Spotlight index.",
        kind: .file, symbol: "folder",
        keywords: "spotlight folder search home documents downloads desktop developer"
    ) { model, _ in AnyView(FilesPane(model: model)) }
}

struct FilesPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .files) {
            Section {
                Picker("Search in", selection: $model.fileScope) {
                    ForEach(FileSearchScope.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .neutralMenus()
            } footer: {
                Text("You can change this in the Files scope too. Narrowing to one folder makes results faster and tighter.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Always skipped") {
                IconRow("Hidden files and folders", symbol: "eye.slash")
                IconRow("Your Library folder", symbol: "books.vertical")
                IconRow("Build products such as node_modules and DerivedData", symbol: "hammer")
                IconRow("Applications, which appear in Everything instead", symbol: "square.grid.2x2")
            }
            Section {
                LabeledContent {
                    Button("Open Spotlight Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!)
                    }
                } label: {
                    SettingRowLabel(title: "Missing files?", detail: "Files uses your existing Spotlight index. Check that your home folder isn't excluded.")
                }
            }
        }
    }
}
