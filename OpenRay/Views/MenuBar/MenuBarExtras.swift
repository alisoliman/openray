import AppKit
import Observation
import SwiftUI

// Menu bar extras: live items in the menu bar that registered commands provide.
//
// A provider offers one by declaring a command with `mode: .menuBar` and adopting
// `MenuBarExtraProviding`. The framework asks for the item's content whenever something the
// content reads changes (Observation), and at least as often as the content's `refresh`. Whether
// an extra is shown is the person's choice, stored per command id; running the command from the
// launcher toggles it. Slice 8 uses this for script commands with `mode: menu-bar`.

/// One entry in an extra's menu.
struct MenuBarExtraItem: Identifiable {
    enum Role: Equatable { case action, label, separator, section }

    var id: String
    var title: String
    var symbol: String? = nil
    var role: Role = .action
    var isEnabled = true
    var isChecked = false
    /// A menu key equivalent shown beside the item, such as "p" with `.command`. Only works while the menu is open.
    var keyEquivalent = ""
    var modifiers: NSEvent.ModifierFlags = []
    var children: [MenuBarExtraItem] = []
    var perform: (@MainActor () -> Void)? = nil

    static func action(
        _ id: String, _ title: String, symbol: String? = nil, isEnabled: Bool = true, isChecked: Bool = false,
        perform: @escaping @MainActor () -> Void
    ) -> MenuBarExtraItem {
        MenuBarExtraItem(id: id, title: title, symbol: symbol, isEnabled: isEnabled, isChecked: isChecked, perform: perform)
    }

    /// Text that can't be clicked, such as an event's time.
    static func label(_ id: String, _ title: String, symbol: String? = nil) -> MenuBarExtraItem {
        MenuBarExtraItem(id: id, title: title, symbol: symbol, role: .label, isEnabled: false)
    }

    /// A small heading over the items that follow.
    static func section(_ id: String, _ title: String) -> MenuBarExtraItem {
        MenuBarExtraItem(id: id, title: title, role: .section, isEnabled: false)
    }

    static func separator(_ id: String) -> MenuBarExtraItem {
        MenuBarExtraItem(id: id, title: "", role: .separator, isEnabled: false)
    }

    static func submenu(_ id: String, _ title: String, symbol: String? = nil, children: [MenuBarExtraItem]) -> MenuBarExtraItem {
        MenuBarExtraItem(id: id, title: title, symbol: symbol, children: children)
    }
}

/// What an extra shows right now.
struct MenuBarExtraContent {
    /// Text beside the symbol, such as “24:59”. Nil shows the symbol alone.
    var title: String?
    /// An SF Symbol, drawn as a template image. Nil shows the title alone; give at least one.
    var symbol: String?
    /// What VoiceOver says for the item.
    var accessibilityLabel: String
    /// The menu a click opens.
    var items: [MenuBarExtraItem] = []
    /// When set, a click runs this instead of opening the menu (the Notes toggle).
    var click: (@MainActor () -> Void)? = nil
    /// Recompute at least this often, for countdowns. Changes the content reads through
    /// Observation update it immediately either way.
    var refresh: Duration? = nil
    /// Digits that change every second stay in place with a monospaced-digit font.
    var usesMonospacedDigits = false
}

/// A provider with `.menuBar` commands.
@MainActor
protocol MenuBarExtraProviding: CommandProvider {
    /// The extra's content right now, or nil to leave the menu bar while there's nothing to show
    /// (no focus session, no upcoming event). Keep it cheap: it runs on every update.
    func menuBarExtra(for command: CommandDescriptor, in model: LauncherModel) -> MenuBarExtraContent?
    /// Whether the extra shows before the person chooses. Default false.
    func menuBarExtraIsShownByDefault(_ command: CommandDescriptor) -> Bool
}

extension MenuBarExtraProviding {
    func menuBarExtraIsShownByDefault(_ command: CommandDescriptor) -> Bool { false }
}

/// The person's choices about the menu bar, kept in `commandPreferences["pref.menuBar"]`.
enum MenuBarExtras {
    static let storageKey = "pref.menuBar"
    static let openRayIconKey = "openray.icon"

    /// Whether the extra for `commandID` is shown, falling back to its provider's default.
    static func isShown(_ commandID: String, default fallback: Bool, in database: LibraryDatabase) -> Bool {
        switch database.commandPreferences[storageKey]?[commandID] {
        case "shown": true
        case "hidden": false
        default: fallback
        }
    }

    @MainActor @discardableResult
    static func setShown(_ shown: Bool, commandID: String, in store: LibraryStore) -> Bool {
        store.update { $0.commandPreferences[storageKey, default: [:]][commandID] = shown ? "shown" : "hidden" }
    }

    /// True when the person hid OpenRay's own menu bar icon. Settings stays reachable from the launcher.
    static func hidesOpenRayIcon(in database: LibraryDatabase) -> Bool {
        database.commandPreferences[storageKey]?[openRayIconKey] == "hidden"
    }

    @MainActor @discardableResult
    static func setHidesOpenRayIcon(_ hides: Bool, in store: LibraryStore) -> Bool {
        store.update { $0.commandPreferences[storageKey, default: [:]][openRayIconKey] = hides ? "hidden" : "shown" }
    }

    /// The standard behavior for running a `.menuBar` command from the launcher: show or hide its
    /// extra, and say which. Providers call this from `perform`.
    @MainActor
    static func toggle(_ command: CommandDescriptor, provider: any MenuBarExtraProviding, in model: LauncherModel) {
        let shown = isShown(command.id, default: provider.menuBarExtraIsShownByDefault(command), in: model.store.database)
        guard setShown(!shown, commandID: command.id, in: model.store) else {
            model.feedback = .error(model.store.errorMessage ?? "The menu bar couldn't be updated.")
            return
        }
        model.toast(shown ? "Removed “\(command.title)” from the menu bar" : "Added “\(command.title)” to the menu bar")
    }

    /// The ⌘K entry that shows or hides an extra.
    @MainActor
    static func toggleAction(_ command: CommandDescriptor, provider: any MenuBarExtraProviding, in model: LauncherModel)
        -> ActionEntry
    {
        let shown = isShown(command.id, default: provider.menuBarExtraIsShownByDefault(command), in: model.store.database)
        return ActionEntry(
            id: "menuBar.toggle", title: shown ? "Remove from Menu Bar" : "Show in Menu Bar",
            symbol: shown ? "menubar.arrow.down.rectangle" : "menubar.arrow.up.rectangle", group: .organize
        ) { [weak model] in
            guard let model else { return }
            toggle(command, provider: provider, in: model)
        }
    }
}

/// One extra to draw.
struct MenuBarExtraSnapshot: Identifiable {
    var id: String
    var content: MenuBarExtraContent
}

/// Which extras show and what they say. Pure reads over the registry, so tests check updates
/// without touching the real menu bar.
@MainActor
enum MenuBarExtrasModel {
    static func snapshots(in model: LauncherModel) -> [MenuBarExtraSnapshot] {
        let database = model.store.database
        var result: [MenuBarExtraSnapshot] = []
        for provider in model.registry.providers {
            guard let extras = provider as? any MenuBarExtraProviding else { continue }
            for command in provider.commands(in: model) where command.mode == .menuBar {
                guard !database.disabledCommandIDs.contains(command.id),
                    MenuBarExtras.isShown(command.id, default: extras.menuBarExtraIsShownByDefault(command), in: database),
                    let content = extras.menuBarExtra(for: command, in: model)
                else { continue }
                result.append(MenuBarExtraSnapshot(id: command.id, content: content))
            }
        }
        return result
    }

    /// The soonest any shown extra asks to be recomputed.
    static func nextRefresh(_ snapshots: [MenuBarExtraSnapshot]) -> Duration? {
        snapshots.compactMap(\.content.refresh).min()
    }
}

/// Draws the extras as status items. It's the only part that touches the real menu bar, and it
/// refuses to start in tests and verification mode.
@MainActor
final class MenuBarExtrasController: NSObject, NSMenuDelegate {
    static let shared = MenuBarExtrasController()

    let guardrail: SideEffectGuard
    private weak var model: LauncherModel?
    private var items: [String: NSStatusItem] = [:]
    private var contents: [String: MenuBarExtraContent] = [:]
    private var refreshTask: Task<Void, Never>?
    private var isUpdateScheduled = false
    private let actions = MenuActionTarget()

    init(guardrail: SideEffectGuard = .current) {
        self.guardrail = guardrail
    }

    /// Starts drawing extras for this launcher. Does nothing in an inert launch.
    func start(model: LauncherModel) {
        guard (try? guardrail.check("adding menu bar items")) != nil else { return }
        self.model = model
        update()
    }

    func stop() {
        refreshTask?.cancel()
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items = [:]
        contents = [:]
        model = nil
    }

    private func scheduleUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        Task { @MainActor [weak self] in
            self?.isUpdateScheduled = false
            self?.update()
        }
    }

    func update() {
        guard let model else { return }
        let snapshots = withObservationTracking {
            MenuBarExtrasModel.snapshots(in: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleUpdate() }
        }
        var seen = Set<String>()
        for snapshot in snapshots {
            seen.insert(snapshot.id)
            let item = items[snapshot.id] ?? makeItem(id: snapshot.id)
            contents[snapshot.id] = snapshot.content
            configure(item, with: snapshot.content, id: snapshot.id)
        }
        for (id, item) in items where !seen.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil
            contents[id] = nil
        }
        refreshTask?.cancel()
        if let interval = MenuBarExtrasModel.nextRefresh(snapshots) {
            refreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
    }

    private func makeItem(id: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "openray.extra.\(id)"
        item.button?.identifier = NSUserInterfaceItemIdentifier("menubar.\(id)")
        items[id] = item
        return item
    }

    private func configure(_ item: NSStatusItem, with content: MenuBarExtraContent, id: String) {
        guard let button = item.button else { return }
        if let symbol = content.symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: content.accessibilityLabel)
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = nil
        }
        let title = content.title.map { content.symbol == nil ? $0 : " " + $0 } ?? ""
        if button.title != title { button.title = title }
        button.font =
            content.usesMonospacedDigits
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .menuBarFont(ofSize: 0)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.setAccessibilityLabel(content.accessibilityLabel)
        if content.click != nil {
            item.menu = nil
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        } else {
            button.target = nil
            button.action = nil
            if item.menu == nil {
                let menu = NSMenu()
                menu.delegate = self
                menu.identifier = NSUserInterfaceItemIdentifier(id)
                item.menu = menu
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let id = items.first(where: { $0.value.button === sender })?.key else { return }
        contents[id]?.click?()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Built when it opens, so the menu shows the content as of now.
        guard let id = menu.identifier?.rawValue else { return }
        update()
        menu.removeAllItems()
        for entry in contents[id]?.items ?? [] { menu.addItem(menuItem(for: entry)) }
    }

    private func menuItem(for entry: MenuBarExtraItem) -> NSMenuItem {
        switch entry.role {
        case .separator: return .separator()
        case .section: return .sectionHeader(title: entry.title)
        case .label, .action:
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.keyEquivalent)
            item.keyEquivalentModifierMask = entry.modifiers
            if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            item.state = entry.isChecked ? .on : .off
            if !entry.children.isEmpty {
                let submenu = NSMenu(title: entry.title)
                for child in entry.children { submenu.addItem(menuItem(for: child)) }
                item.submenu = submenu
            } else if entry.role == .action, let perform = entry.perform {
                item.target = actions
                item.action = #selector(MenuActionTarget.run(_:))
                item.representedObject = MenuAction(perform: perform)
            }
            item.isEnabled = entry.role == .action && entry.isEnabled && (entry.perform != nil || !entry.children.isEmpty)
            return item
        }
    }
}

private final class MenuAction: NSObject {
    let perform: @MainActor () -> Void
    init(perform: @escaping @MainActor () -> Void) { self.perform = perform }
}

@MainActor
private final class MenuActionTarget: NSObject {
    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.perform()
    }
}
