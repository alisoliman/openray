import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsPane {
    static let focus = SettingsPane(
        id: "focus", title: "Focus",
        subtitle: "Focus sessions: length, block or allow lists, and app categories.",
        kind: .command, symbol: "scope",
        keywords: "focus session pomodoro block allow list categories apps distraction timer snooze pause menu bar"
    ) { model, _ in AnyView(FocusPane(model: model)) }
}

struct FocusPane: View {
    @Bindable var model: LauncherModel
    @State private var expanded: String?

    private var preferences: FocusPreferences { .load(from: model.store) }
    private var categories: [FocusCategory] { FocusCategory.resolve(model.store.database.focusCategories) }

    var body: some View {
        SettingsPaneScaffold(pane: .focus) {
            Section("Next session") {
                Picker("Usual length", selection: binding(\.minutes)) {
                    ForEach(FocusPreferences.presets, id: \.self) { Text(FocusFormat.duration(minutes: $0)).tag($0) }
                    Text("No time limit").tag(0)
                }
                .neutralMenus()
                HStack(alignment: .firstTextBaseline) {
                    SettingRowLabel(
                        title: "Mode",
                        detail: preferences.mode == .block
                            ? "Apps in the chosen categories are hidden when they come forward."
                            : "Only apps in the chosen categories, and the system's own, can come forward.")
                    Spacer()
                    SegmentedPicker(
                        options: FocusMode.allCases.map { ($0, $0.title) }, selection: binding(\.mode),
                        accessibilityLabel: "Mode")
                }
            }
            Section {
                ForEach(categories) { category in
                    FocusCategoryRow(
                        model: model, category: category, isOn: included(category.id),
                        isExpanded: Binding(get: { expanded == category.id }, set: { expanded = $0 ? category.id : nil }))
                }
                Button("New Category", systemImage: "plus") { addCategory() }
            } header: {
                Text("Categories")
            } footer: {
                Text("Switched-on categories are used by the next session. Websites aren't blocked.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle(isOn: menuBarBinding) {
                    SettingRowLabel(
                        title: "Timer in the menu bar", detail: "While a session runs: time left, pause, snooze and complete.")
                }
                .settingsSwitch()
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<FocusPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: path] },
            set: { value in
                var updated = preferences
                updated[keyPath: path] = value
                updated.save(to: model.store)
            })
    }

    private func included(_ id: String) -> Binding<Bool> {
        Binding(
            get: { preferences.categoryIDs.contains(id) },
            set: { on in
                var updated = preferences
                updated.categoryIDs.removeAll { $0 == id }
                if on { updated.categoryIDs.append(id) }
                updated.save(to: model.store)
            })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { MenuBarExtras.isShown(FocusCommandProvider.menuBarID, default: true, in: model.store.database) },
            set: { MenuBarExtras.setShown($0, commandID: FocusCommandProvider.menuBarID, in: model.store) })
    }

    private func addCategory() {
        let record = FocusCategoryRecord(id: UUID().uuidString, name: "New Category", symbol: "square.grid.2x2", bundleIDs: [])
        if model.store.update({ $0.focusCategories.append(record) }) { expanded = record.id }
    }
}

/// Saving category edits: an edit to a built-in stores an override with its id.
enum FocusCategoryEditing {
    static func upsert(_ category: FocusCategory, in database: inout LibraryDatabase) {
        var record = category.record
        if let index = database.focusCategories.firstIndex(where: { $0.id == category.id }) {
            record.isHidden = database.focusCategories[index].isHidden
            database.focusCategories[index] = record
        } else {
            database.focusCategories.append(record)
        }
    }

    /// Hides a built-in or deletes the person's own category.
    static func remove(_ category: FocusCategory, in database: inout LibraryDatabase) {
        if category.isBuiltIn {
            if let index = database.focusCategories.firstIndex(where: { $0.id == category.id }) {
                database.focusCategories[index].isHidden = true
            } else {
                database.focusCategories.append(FocusCategoryRecord(id: category.id, isHidden: true))
            }
        } else {
            database.focusCategories.removeAll { $0.id == category.id }
        }
    }

    /// Puts a built-in back the way it shipped.
    static func reset(_ category: FocusCategory, in database: inout LibraryDatabase) {
        database.focusCategories.removeAll { $0.id == category.id }
    }
}

private struct FocusCategoryRow: View {
    @Bindable var model: LauncherModel
    let category: FocusCategory
    @Binding var isOn: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if !category.isBuiltIn {
                TextField(
                    "Name",
                    text: Binding(
                        get: { category.name },
                        set: { name in
                            var updated = category
                            updated.name = name
                            model.store.update { FocusCategoryEditing.upsert(updated, in: &$0) }
                        }))
            }
            ForEach(category.bundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    AppIcon(bundleID: bundleID)
                    Text(Self.appName(for: bundleID)).lineLimit(1)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        var updated = category
                        updated.bundleIDs.removeAll { $0 == bundleID }
                        model.store.update { FocusCategoryEditing.upsert(updated, in: &$0) }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(Self.appName(for: bundleID))")
                }
            }
            HStack {
                Button("Add App…", systemImage: "plus") { addApp() }
                Spacer()
                if category.isBuiltIn, model.store.database.focusCategories.contains(where: { $0.id == category.id }) {
                    Button("Reset") { model.store.update { FocusCategoryEditing.reset(category, in: &$0) } }
                }
                Button(category.isBuiltIn ? "Hide Category" : "Delete Category", role: .destructive) {
                    model.store.update { FocusCategoryEditing.remove(category, in: &$0) }
                }
            }
            .buttonStyle(.borderless)
        } label: {
            Toggle(isOn: $isOn) {
                Label {
                    SettingRowLabel(
                        title: category.name,
                        detail: "\(category.bundleIDs.count) app\(category.bundleIDs.count == 1 ? "" : "s")\(category.isBuiltIn ? " · Built in" : "")")
                } icon: {
                    Image(systemName: category.symbol).foregroundStyle(.secondary)
                }
            }
            .settingsSwitch()
        }
    }

    /// Asks for an app with an open panel. Refused in tests and verification mode.
    private func addApp() {
        guard (try? SideEffectGuard.check("showing an open panel")) != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "Add Apps to \(category.name)"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var updated = category
        for bundleID in added where !updated.bundleIDs.contains(bundleID) { updated.bundleIDs.append(bundleID) }
        model.store.update { FocusCategoryEditing.upsert(updated, in: &$0) }
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").frame(width: 18, height: 18).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
    }
}
