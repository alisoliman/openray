import Foundation

/// Launcher commands for the menu bar itself: OpenRay's icon can be hidden in Settings, so the
/// launcher can always bring it back, and open the Menu Bar settings.
@MainActor
final class MenuBarCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "menubar", bindablePrefixes: ["menubar."]) {
        MenuBarCommandProvider()
    }

    static let toggleIconID = "menubar.toggleIcon"
    static let settingsID = "menubar.settings"

    var id: String { Self.registration.id }

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let hidden = MenuBarExtras.hidesOpenRayIcon(in: model.store.database)
        return [
            CommandDescriptor(
                id: Self.toggleIconID, title: hidden ? "Show OpenRay in Menu Bar" : "Hide OpenRay from Menu Bar",
                subtitle: hidden ? "Bring back OpenRay's menu bar icon" : "Settings stays in the launcher and on ⌘,",
                kind: .system, symbol: "menubar.rectangle", keywords: ["menu bar", "icon", "status item", "tray"],
                mode: .noView),
            CommandDescriptor(
                id: Self.settingsID, title: "Menu Bar Settings", subtitle: "OpenRay's icon and the items commands add",
                kind: .system, symbol: "gearshape", keywords: ["menu bar", "extras", "settings", "preferences"], mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.toggleIconID:
            let hidden = MenuBarExtras.hidesOpenRayIcon(in: model.store.database)
            guard MenuBarExtras.setHidesOpenRayIcon(!hidden, in: model.store) else {
                model.feedback = .error(model.store.errorMessage ?? "The menu bar couldn't be updated.")
                return
            }
            model.toast(hidden ? "OpenRay is back in the menu bar" : "OpenRay's menu bar icon is hidden")
        case Self.settingsID:
            model.openSettings(.menuBar)
        default:
            break
        }
    }
}
