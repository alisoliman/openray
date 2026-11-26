import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Why Settings can't save, shown once at the top of each pane. Nil when the library is writable.
    @Entry var settingsStoreError: String? = nil
}

/// A pane: native grouped form sections. The title and description live in the toolbar.
struct SettingsPaneScaffold<Content: View>: View {
    var pane: SettingsPane
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.settingsStoreError) private var storeError

    var body: some View {
        Form {
            if let storeError {
                Section {
                    Label {
                        SettingRowLabel(title: "Changes can't be saved", detail: storeError)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(OR.Color.danger)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            content
        }
        .formStyle(.grouped)
    }
}

struct SettingRowLabel: View {
    var title: String
    var detail: String?
    /// A disabled row dims its words too, not only its control.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(isEnabled ? .primary : .tertiary)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(isEnabled ? .secondary : .tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension LauncherModel {
    func preference<Value>(_ path: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.store.database.preferences[keyPath: path] },
            set: { value in
                if self.store.update({ $0.preferences[keyPath: path] = value }) { self.applyPreferences() }
            })
    }

    func optionalPreference(_ path: WritableKeyPath<AppPreferences, Bool?>, default fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { self.store.database.preferences[keyPath: path] ?? fallback },
            set: { value in
                if self.store.update({ $0.preferences[keyPath: path] = value }) { self.applyPreferences() }
            })
    }

    /// A bindable command's title and alias, which the Settings search matches.
    func settingsSearchText(for command: LauncherItem) -> String {
        [command.title, commandBinding(for: command.id).alias].compactMap { $0 }.joined(separator: " ")
    }
}

extension View {
    /// Settings tints with the accent text token so titles stay readable; switches use the fill
    /// token, like the launcher's switches and the design system's `.switch.on`.
    func settingsSwitch() -> some View { tint(OR.Color.accentFill) }

    /// Pop-up values in the text color, as the design system's dropdowns are, not in Ray.
    func neutralMenus() -> some View { tint(.primary) }
}

/// A symbol and a sentence, with the symbols in one fixed-width column so the text lines up.
struct IconRow: View {
    var text: String
    var symbol: String

    init(_ text: String, symbol: String) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
    }
}

enum SystemSettingsLink {
    enum Pane { case accessibility, pasteboard }

    static func open(_ pane: Pane) {
        let string =
            switch pane {
            case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .pasteboard: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
            }
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
