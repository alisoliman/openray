import AppKit
import SwiftUI

extension SettingsPane {
    static let screenshots = SettingsPane(
        id: "screenshots", title: "Screenshots",
        subtitle: "Folders Search Screenshots watches, text recognition and retention.",
        kind: .file, symbol: "camera.viewfinder",
        keywords: "screenshot screen capture ocr text recognition folders columns grid retention index desktop"
    ) { model, _ in AnyView(ScreenshotsPane(model: model)) }
}

struct ScreenshotsPane: View {
    let model: LauncherModel

    var body: some View {
        let settings = model.screenshotSettings
        let index = model.screenshotsProvider?.index
        SettingsPaneScaffold(pane: .screenshots) {
            Section {
                LabeledContent("Screenshot folder") {
                    Text(LauncherModel.shortenedPath(ScreenshotLocation.system())).foregroundStyle(.secondary)
                }
                Toggle(isOn: binding(\.watchesDesktop)) {
                    SettingRowLabel(title: "Also watch the Desktop", detail: "For screenshots saved there by other apps.")
                }
                .settingsSwitch()
                Toggle(isOn: binding(\.includesAllImages)) {
                    SettingRowLabel(
                        title: "Include all images",
                        detail: "Index every image in the screenshot folder, not only screenshots.")
                }
                .settingsSwitch()
            } footer: {
                Text("The screenshot folder is the one you choose in the Screenshot app (⇧⌘5 › Options).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            FolderListSection(
                title: "More folders", emptyText: "No other folders",
                footer: "Every image in these folders is indexed, such as a screenshot app's own folder.",
                folders: settings.extraFolders, prompt: "Add Folder"
            ) { folders in model.updateScreenshotSettings { $0.extraFolders = folders } }
            Section {
                Toggle(isOn: binding(\.recognizesText)) {
                    SettingRowLabel(
                        title: "Recognize text", detail: "Read the text in each screenshot on this Mac, for text: searches and Copy Text.")
                }
                .settingsSwitch()
                Picker("Recognition", selection: binding(\.accurateRecognition)) {
                    Text("Fast").tag(false)
                    Text("Accurate").tag(true)
                }
                .neutralMenus()
                .disabled(!settings.recognizesText)
            } header: {
                Text("Text recognition")
            } footer: {
                Text("Accurate reads small and stylized text better and uses more energy. Changing it reads every screenshot again.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section {
                Picker("Columns", selection: binding(\.columns)) {
                    ForEach(Array(ScreenshotSettings.columnRange), id: \.self) { Text("\($0)").tag($0) }
                }
                .neutralMenus()
                Picker("Keep in index", selection: binding(\.retentionDays)) {
                    ForEach(ScreenshotSettings.retentionChoices, id: \.self) { days in
                        Text(ScreenshotSettings.retentionTitle(days)).tag(days)
                    }
                }
                .neutralMenus()
                if let index {
                    LabeledContent {
                        Button("Refresh") { Task { await index.refresh() } }.disabled(index.isScanning)
                    } label: {
                        SettingRowLabel(
                            title: "\(index.records.count.formatted()) screenshots indexed",
                            detail: index.pendingRecognition > 0
                                ? "Reading text in \(index.pendingRecognition.formatted()) more…"
                                : (index.lastError ?? "The index is kept beside your library, on this Mac."))
                    }
                }
            } header: {
                Text("Search Screenshots")
            } footer: {
                Text("Retention only limits what Search Screenshots lists. Your screenshot files are never deleted. ⌘+ and ⌘- change the columns in the grid too.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<ScreenshotSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.screenshotSettings[keyPath: path] },
            set: { value in model.updateScreenshotSettings { $0[keyPath: path] = value } })
    }
}
