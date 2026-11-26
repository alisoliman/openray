import SwiftUI

extension SettingsPane {
    static let menuBar = SettingsPane(
        id: "menuBar", title: "Menu Bar",
        subtitle: "OpenRay's icon and the live items commands add to the menu bar.",
        kind: .system, symbol: "menubar.rectangle",
        keywords: "menu bar icon hide status item extras focus timer next event notes toggle"
    ) { model, _ in AnyView(MenuBarPane(model: model)) }
}

struct MenuBarPane: View {
    @Bindable var model: LauncherModel

    var body: some View {
        SettingsPaneScaffold(pane: .menuBar) {
            Section {
                Toggle(isOn: iconBinding) {
                    SettingRowLabel(
                        title: "Show OpenRay in the menu bar",
                        detail: "When it's hidden, open Settings from the launcher: search “Settings”, or press ⌘, while it's open.")
                }
                .settingsSwitch()
            } header: {
                Text("OpenRay")
            }
            Section {
                ForEach(extras, id: \.command.id) { extra in
                    Toggle(isOn: shownBinding(extra.command, default: extra.shownByDefault)) {
                        Label {
                            SettingRowLabel(title: extra.command.title, detail: extra.command.subtitle)
                        } icon: {
                            Image(systemName: extra.command.symbol).foregroundStyle(.secondary)
                        }
                    }
                    .settingsSwitch()
                }
            } header: {
                Text("Menu bar items")
            } footer: {
                Text("Items appear only while they have something to show, such as a running focus session.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Every `.menuBar` command any provider offers, in registration order.
    private var extras: [(command: CommandDescriptor, shownByDefault: Bool)] {
        model.registry.providers.flatMap { provider -> [(command: CommandDescriptor, shownByDefault: Bool)] in
            guard let extras = provider as? any MenuBarExtraProviding else { return [] }
            return provider.commands(in: model).filter { $0.mode == .menuBar }.map {
                ($0, extras.menuBarExtraIsShownByDefault($0))
            }
        }
    }

    private var iconBinding: Binding<Bool> {
        Binding(
            get: { !MenuBarExtras.hidesOpenRayIcon(in: model.store.database) },
            set: { MenuBarExtras.setHidesOpenRayIcon(!$0, in: model.store) })
    }

    private func shownBinding(_ command: CommandDescriptor, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { MenuBarExtras.isShown(command.id, default: fallback, in: model.store.database) },
            set: { MenuBarExtras.setShown($0, commandID: command.id, in: model.store) })
    }
}
