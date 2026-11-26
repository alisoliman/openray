import AppKit
import SwiftUI

extension SettingsPane {
    static let windows = SettingsPane(
        id: "windows", title: "Windows",
        subtitle: "Gaps, half cycling and saved window layouts.",
        kind: .window, symbol: "macwindow",
        keywords: "window management gaps spacing cycle halves thirds layouts arrangement tile snap"
    ) { model, _ in AnyView(WindowsPane(model: model)) }
}

struct WindowsPane: View {
    @Bindable var model: LauncherModel

    static let gapChoices: [Double] = [0, 4, 6, 8, 10, 12, 16, 20, 24, 32]

    private var settings: WindowManagementSettings { model.store.database.windowManagementSettings }

    var body: some View {
        SettingsPaneScaffold(pane: .windows) {
            Section {
                Picker(selection: gap(\.window)) {
                    ForEach(Self.gapChoices, id: \.self) { Text(Self.gapTitle($0)).tag($0) }
                } label: {
                    SettingRowLabel(title: "Gap between windows", detail: "Space between tiled neighbours.")
                }
                .neutralMenus()
                Picker(selection: gap(\.screen)) {
                    ForEach(Self.gapChoices, id: \.self) { Text(Self.gapTitle($0)).tag($0) }
                } label: {
                    SettingRowLabel(title: "Gap at screen edges", detail: "Space between windows and the edges of the display.")
                }
                .neutralMenus()
                Toggle(isOn: cycling) {
                    SettingRowLabel(
                        title: "Cycle sizes when repeating a half",
                        detail: "Pressing Left, Right, Top or Bottom Half again steps through ½, ⅔ and ⅓.")
                }
                .settingsSwitch()
            } header: {
                Text("Arranging")
            } footer: {
                Text("With no gaps and no cycling, the original window commands behave exactly as before.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section {
                let layouts = model.store.database.windowLayouts
                if layouts.isEmpty {
                    Text("No saved layouts yet. Run Save Current Layout to remember the windows on screen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(layouts) { record in
                    WindowLayoutSettingsRow(model: model, record: record)
                }
            } header: {
                Text("Layouts")
            } footer: {
                Text("Run a layout from search, or give it an alias or a hotkey in Shortcuts. Up to eight windows per display.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Text(model.accessibilityAllowed ? "Allowed" : "Not allowed")
                        .foregroundStyle(model.accessibilityAllowed ? OR.Color.success : OR.Color.warning)
                } label: {
                    SettingRowLabel(
                        title: "Accessibility",
                        detail: "Window commands, Switch Windows and layouts move other apps' windows through Accessibility.")
                }
            }
        }
    }

    static func gapTitle(_ value: Double) -> String { value == 0 ? "None" : "\(Int(value)) pt" }

    private func gap(_ path: WritableKeyPath<WindowGaps, Double>) -> Binding<Double> {
        Binding(
            get: {
                // A stored value that isn't one of the choices shows as the nearest one.
                let value = settings.gaps[keyPath: path]
                return Self.gapChoices.min { abs($0 - value) < abs($1 - value) } ?? 0
            },
            set: { value in
                var gaps = settings.gaps
                gaps[keyPath: path] = value
                save { $0.gaps = WindowGaps(window: gaps.window, screen: gaps.screen) }
            })
    }

    private var cycling: Binding<Bool> {
        Binding(get: { settings.cyclesHalves }, set: { value in save { $0.cyclesHalves = value } })
    }

    private func save(_ change: (inout WindowManagementSettings) -> Void) {
        var next = settings
        change(&next)
        _ = model.store.update { $0.windowManagementSettings = next }
    }
}

/// One saved layout: its name, what happens to other windows, and Delete.
struct WindowLayoutSettingsRow: View {
    let model: LauncherModel
    let record: WindowLayoutRecord
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Layout name", text: $name, prompt: Text(record.displayName))
                    .textFieldStyle(.plain)
                    .onSubmit(rename)
                    .accessibilityLabel("Layout name")
                Text(Self.summary(of: record)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Other windows", selection: otherWindows) {
                ForEach(SavedWindowLayout.OtherWindows.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .neutralMenus()
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete “\(record.displayName)”")
            .accessibilityLabel("Delete \(record.displayName)")
        }
        .onAppear { name = record.name }
        .onChange(of: record.name) { _, new in name = new }
    }

    static func summary(of record: WindowLayoutRecord) -> String {
        let apps = record.slots.map(\.appName)
        let count = record.slots.count == 1 ? "1 window" : "\(record.slots.count) windows"
        return apps.isEmpty ? count : "\(count): \(apps.prefix(4).joined(separator: ", "))\(apps.count > 4 ? "…" : "")"
    }

    private var otherWindows: Binding<SavedWindowLayout.OtherWindows> {
        Binding(
            get: { record.otherWindows },
            set: { value in update { $0.otherWindows = value } })
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != record.name, trimmed.count <= 60 else { return }
        update { $0.name = trimmed }
    }

    private func update(_ change: (inout WindowLayoutRecord) -> Void) {
        let id = record.id
        if model.store.update({ database in
            guard let index = database.windowLayouts.firstIndex(where: { $0.id == id }) else { return }
            change(&database.windowLayouts[index])
        }) {
            model.commandCatalogDidChange()
        }
    }

    private func delete() {
        if Self.delete(record.id, in: model.store) { model.commandCatalogDidChange() }
    }

    /// One save: the layout goes with its favorite and usage records, or nothing changes (the
    /// pane shows the store's error). A binding stays, inactive, as for any missing command.
    @discardableResult
    static func delete(_ id: UUID, in store: LibraryStore) -> Bool {
        let itemID = WindowCommandProvider.layoutPrefix + id.uuidString
        return store.update { database in
            database.windowLayouts.removeAll { $0.id == id }
            database.favoriteIDs.remove(itemID)
            database.usage.removeAll { $0.id == itemID }
        }
    }
}
