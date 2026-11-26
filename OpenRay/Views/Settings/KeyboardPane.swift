import AppKit
import SwiftUI

extension SettingsPane {
    static let keyboard = SettingsPane(
        id: "keyboard", title: "Keyboard",
        subtitle: "The Hyper key, and how keys move through the launcher.",
        kind: .command, symbol: "keyboard.badge.ellipsis",
        keywords: "hyper key caps lock modifier vim emacs escape esc navigation control j k"
    ) { model, _ in AnyView(KeyboardPane(model: model)) }
}

struct KeyboardPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .keyboard) {
            Section {
                Toggle(isOn: hyper(\.isEnabled)) {
                    SettingRowLabel(
                        title: "Use Caps Lock as the Hyper key",
                        detail: "Hold Caps Lock for ⌃⌥⇧⌘, so any key becomes a shortcut no app uses. Needs Accessibility.")
                }
                .settingsSwitch()
                .accessibilityIdentifier("keyboard.hyper")
                Toggle(isOn: hyper(\.includesShift)) {
                    SettingRowLabel(title: "Include Shift", detail: "Off makes the Hyper key ⌃⌥⌘.")
                }
                .settingsSwitch()
                .disabled(!model.store.database.preferences.hyper.isEnabled)
                Picker("A quick press of Caps Lock", selection: hyper(\.quickPress)) {
                    ForEach(HyperKeyQuickPress.allCases) { Text($0.title).tag($0) }
                }
                .neutralMenus()
                .disabled(!model.store.database.preferences.hyper.isEnabled)
                if let problem = model.hyperKey.problem, model.store.database.preferences.hyper.isEnabled {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(OR.Color.warning)
                        .font(.system(size: 12))
                }
            } header: {
                Text("Hyper Key")
            } footer: {
                Text(
                    "OpenRay remaps Caps Lock to F18 for this session and removes the remap when you turn this off."
                )
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Section("Navigation") {
                Toggle(isOn: model.optionalPreference(\.vimNavigation)) {
                    SettingRowLabel(
                        title: "Move with ⌃J and ⌃K",
                        detail: "Vim-style, beside ⌃N and ⌃P, which always work.")
                }
                .settingsSwitch()
                Picker("Esc", selection: escape) {
                    ForEach(EscapeBehavior.allCases) { Text($0.title).tag($0) }
                }
                .neutralMenus()
                LabeledContent("Back to Everything") { KeyCaps(["⌘", "esc"], size: .small) }
                LabeledContent("Close the window") { KeyCaps(["⌘", "W"], size: .small) }
                LabeledContent("Jump between sections") { KeyCaps(["⌘", "↑", "↓"], size: .small) }
            }
        }
    }

    private func hyper<Value>(_ path: WritableKeyPath<HyperKeySettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.store.database.preferences.hyper[keyPath: path] },
            set: { value in
                var settings = model.store.database.preferences.hyper
                settings[keyPath: path] = value
                if model.store.update({ $0.preferences.hyperKey = settings }) { model.applyPreferences() }
            })
    }

    private var escape: Binding<EscapeBehavior> {
        Binding(
            get: { model.store.database.preferences.escapeBehavior ?? .navigateBack },
            set: { value in model.store.update { $0.preferences.escapeBehavior = value } })
    }
}
