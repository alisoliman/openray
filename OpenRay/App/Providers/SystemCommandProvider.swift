import AppKit
import SwiftUI

/// System commands, sound devices and Search Menu Bar Items through the registry. No-view
/// commands close the panel, run through the executor and report in the HUD.
@MainActor
final class SystemCommandProvider: CommandProvider {
    nonisolated static let providerID = "system"
    nonisolated static let registration = CommandProviderRegistration(
        id: providerID, bindablePrefixes: ["system."]
    ) { SystemCommandProvider() }

    nonisolated static let soundOutputID = "system.soundOutput"
    nonisolated static let soundInputID = "system.soundInput"
    nonisolated static let menuSearchID = "system.searchMenuBarItems"
    // Row ids inside the scopes; never commands.
    nonisolated static let volumeRowID = "system.volume.row"
    nonisolated static let deviceRowID = "system.sound.row"
    nonisolated static let menuRowID = "system.menu.row"

    nonisolated static let volumeScope = ProvidedScope(
        id: "system.volume", provider: providerID, title: "Set Volume", symbol: "speaker.wave.2.fill", kind: .system,
        placeholder: "Volume from 0 to 100", summary: "Set the output volume to a percentage", shortTitle: "Volume",
        itemNoun: "level", ranksItems: false)
    nonisolated static let outputScope = ProvidedScope(
        id: "system.sound.output", provider: providerID, title: "Sound Output", symbol: "hifispeaker.2", kind: .system,
        placeholder: "Search output devices", summary: "Choose where sound plays", shortTitle: "Output",
        itemNoun: "output device")
    nonisolated static let inputScope = ProvidedScope(
        id: "system.sound.input", provider: providerID, title: "Sound Input", symbol: "mic", kind: .system,
        placeholder: "Search input devices", summary: "Choose the microphone apps use", shortTitle: "Input",
        itemNoun: "input device")
    nonisolated static let menuScope = ProvidedScope(
        id: "system.menu", provider: providerID, title: "Search Menu Bar Items", symbol: "filemenu.and.selection",
        kind: .command, placeholder: "Search the menus of the app you were using",
        summary: "Run any menu item of the app you were using", shortTitle: "Menus", itemNoun: "menu item",
        ranksItems: false)

    let executor: any SystemActionPerforming
    let audio: any AudioDeviceControlling
    let menuSearch: MenuItemSearch
    let hud: HUDController
    /// The app that was frontmost when the launcher opened. Never the window-chip target.
    let foreground: @MainActor (LauncherModel) -> AppIdentity?
    /// The last command run, so tests can wait for it.
    private(set) var pendingTask: Task<Void, Never>?
    /// Menu items read when the scope opened, filtered locally after.
    private var menuSnapshot: (pid: pid_t, snapshot: MenuSnapshot)?
    private var menuError: String?

    convenience init() {
        self.init(
            executor: SystemActionEnvironment.makeDefault(), audio: AudioDeviceEnvironment.makeDefault(),
            menuSearch: MenuItemSearch(), hud: .shared)
    }

    init(
        executor: any SystemActionPerforming, audio: any AudioDeviceControlling, menuSearch: MenuItemSearch,
        hud: HUDController,
        foreground: @escaping @MainActor (LauncherModel) -> AppIdentity? = { model in
            model.previousApplication.flatMap { $0.isTerminated ? nil : AppIdentity($0) }
        }
    ) {
        self.executor = executor
        self.audio = audio
        self.menuSearch = menuSearch
        self.hud = hud
        self.foreground = foreground
    }

    var id: String { Self.providerID }

    func context(in model: LauncherModel) -> SystemCommandContext {
        SystemCommandContext(
            foregroundApplication: foreground(model),
            excludedBundleIdentifiers: Set(model.store.database.systemCommandSettings.quitExclusions))
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let settings = model.store.database.systemCommandSettings
        let context = context(in: model)
        // Commands about the app you were using can't run without one; they say so instead of asking.
        let hasForeground = (try? context.requireForeground("")) != nil
        let needsForeground: Set<SystemCommand.ID> = [.hideOtherApps, .quitAllAppsExceptFrontmost, .restartFrontmostApp]
        var descriptors = SystemCommand.all.map { command in
            let asks = settings.asksFirst(command.id) && (hasForeground || !needsForeground.contains(command.id))
            return CommandDescriptor(
                id: command.id.itemID, title: command.title, subtitle: command.subtitle, kind: .system,
                symbol: command.symbol, keywords: command.keywords.split(separator: " ").map(String.init),
                arguments: command.takesArgument
                    ? [ArgumentSpec(name: "level", placeholder: command.argumentPlaceholder ?? "Percent", isOptional: true)]
                    : [],
                // Set Volume asks for its level in its own list, so a hotkey shows it rather than failing.
                mode: command.id == .setVolume ? .view(.provided(Self.volumeScope)) : .noView, badge: "System",
                confirmation: asks ? command.confirmation(for: context).map { Self.confirmation($0, for: command.id) } : nil)
        }
        descriptors += [
            CommandDescriptor(
                id: Self.soundOutputID, title: "Sound Output", subtitle: Self.outputScope.summary, kind: .system,
                symbol: Self.outputScope.symbol, keywords: ["sound", "audio", "output", "speakers", "headphones", "device"],
                mode: .view(.provided(Self.outputScope))),
            CommandDescriptor(
                id: Self.soundInputID, title: "Sound Input", subtitle: Self.inputScope.summary, kind: .system,
                symbol: Self.inputScope.symbol, keywords: ["sound", "audio", "input", "microphone", "mic", "device"],
                mode: .view(.provided(Self.inputScope))),
            CommandDescriptor(
                id: Self.menuSearchID, title: "Search Menu Bar Items", subtitle: Self.menuScope.summary, kind: .command,
                symbol: Self.menuScope.symbol, keywords: ["menu", "menu bar", "items", "actions", "commands"],
                mode: .view(.provided(Self.menuScope))),
        ]
        return descriptors
    }

    nonisolated static func confirmation(_ text: SystemCommand.Confirmation, for id: SystemCommand.ID)
        -> CommandConfirmation
    {
        let detail =
            switch id {
            case .restart, .shutDown, .logOut: "Open apps can ask to save their documents first."
            case .emptyTrash: "This can't be undone."
            case .quitAllApps, .quitAllAppsExceptFrontmost:
                "Apps can ask to save first. Apps excluded in Settings › System keep running."
            default: ""
            }
        return CommandConfirmation(question: text.title, detail: detail, confirmTitle: text.button)
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case Self.volumeRowID: "Set Volume"
        case Self.deviceRowID: ref.has(.unavailable) ? "Current Device" : "Use This Device"
        case Self.menuRowID: ref.has(.unavailable) ? "Unavailable Right Now" : "Run Menu Item"
        default: nil
        }
    }

    // MARK: Perform

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        if let id = SystemCommand.ID(itemID: ref.id) {
            let command = SystemCommand.command(id)
            let action: SystemAction
            do {
                action = try command.action(argument: ref.arguments["level"], context: context(in: model))
            } catch {
                // Said in the panel, before it closes: nothing has run.
                model.feedback = .warning(error.localizedDescription)
                return
            }
            model.store.recordUse(of: item.id)
            run(action, reporting: command, in: model)
            return
        }
        switch ref.id {
        case Self.volumeRowID:
            guard let level = ref.payload.flatMap(Double.init) else { return }
            run(.volume(.set(level)), reporting: SystemCommand.command(.setVolume), in: model)
        case Self.deviceRowID:
            chooseDevice(ref.payload, in: model)
        case Self.menuRowID:
            pressMenuItem(ref.payload, in: model)
        default:
            break
        }
    }

    /// Closes the panel, then runs the action and shows what happened in the HUD.
    private func run(_ action: SystemAction, reporting command: SystemCommand, in model: LauncherModel) {
        model.panel?.dismiss(restoreFocus: true)
        let executor = executor
        let hud = hud
        pendingTask = Task { @MainActor in
            do {
                let result = try await executor.perform(action)
                if let message = command.hud(for: result) { hud.show(message) }
            } catch {
                hud.show(HUDMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .error))
            }
        }
    }

    // MARK: Set Volume

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        switch scope.id {
        case Self.volumeScope.id: return volumeRows(query: query, argument: scope.arguments["level"])
        case Self.outputScope.id: return deviceRows(.output)
        case Self.inputScope.id: return deviceRows(.input)
        default: return []
        }
    }

    /// The typed level first, then every tenth when nothing is typed.
    nonisolated static func volumeLevels(query: String, argument: String?) -> [Double] {
        let typed = query.isEmpty ? argument : query
        var levels: [Double] = []
        if let typed, let level = try? VolumeArgument.parse(typed) { levels.append(level) }
        if query.isEmpty {
            levels += stride(from: 100, through: 0, by: -10).map { Double($0) / 100 }.filter { !levels.contains($0) }
        }
        return levels
    }

    private func volumeRows(query: String, argument: String?) -> [LauncherItem] {
        Self.volumeLevels(query: query, argument: argument).map { level in
            let percent = SystemCommand.percent(level)
            return LauncherItem(
                id: "system.volume.\(percent)", title: "Set Volume to \(percent)", subtitle: "Output volume",
                symbol: SystemCommand.volumeSymbol(level), kind: .system, badge: "Volume",
                action: .provided(
                    ProvidedRef(provider: id, id: Self.volumeRowID, payload: String(level), primaryTitle: "Set Volume", traits: [])))
        }
    }

    // MARK: Sound devices

    private func deviceRows(_ scope: AudioScope) -> [LauncherItem] {
        let current = audio.defaultDevice(for: scope)
        return audio.devices(for: scope).map { device in
            let isCurrent = device.uid == current?.uid
            return LauncherItem(
                id: "system.sound.\(scope.rawValue).\(device.uid)", title: device.name,
                subtitle: isCurrent ? "Current \(scope.title.lowercased())" : scope.title,
                symbol: device.symbol(for: scope), kind: .system, badge: isCurrent ? "Current" : "",
                action: .provided(
                    ProvidedRef(
                        provider: id, id: Self.deviceRowID, payload: "\(scope.rawValue):\(device.uid)",
                        traits: isCurrent ? [.unavailable] : [])))
        }
    }

    private func chooseDevice(_ payload: String?, in model: LauncherModel) {
        let parts = (payload ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let scope = AudioScope(rawValue: parts[0]),
            let device = audio.devices(for: scope).first(where: { $0.uid == parts[1] })
        else {
            model.feedback = .error("That sound device is no longer connected.")
            return
        }
        do {
            try audio.setDefaultDevice(device, for: scope)
            model.panel?.dismiss(restoreFocus: true)
            hud.show(HUDMessage("\(scope.title): \(device.name)", symbol: device.symbol(for: scope)))
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    // MARK: Search Menu Bar Items

    var providesLiveItems: Bool { true }

    /// Reads the menus once when the scope opens, off the main actor, then filters locally.
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        guard scope?.id == Self.menuScope.id else { return [] }
        guard let pid = foreground(model)?.pid else {
            menuError = "Open OpenRay from the app whose menus you want to search."
            return []
        }
        if query.isEmpty || menuSnapshot?.pid != pid {
            do {
                menuSnapshot = (pid, try await menuSearch.items(for: pid))
                menuError = nil
            } catch is CancellationError {
                return []
            } catch {
                menuSnapshot = nil
                menuError = error.localizedDescription
                return []
            }
        }
        guard !Task.isCancelled, let snapshot = menuSnapshot?.snapshot else { return [] }
        return MenuItemSearch.filter(snapshot.items, query: query).prefix(100).map { menuRow($0) }
    }

    private func menuRow(_ item: MenuBarItem) -> LauncherItem {
        LauncherItem(
            id: "system.menu.\(item.id)", title: item.title, subtitle: item.menuText, symbol: "filemenu.and.selection",
            kind: .command, badge: item.shortcut?.joined() ?? "", keywords: item.pathText,
            action: .provided(
                ProvidedRef(
                    provider: id, id: Self.menuRowID, payload: item.id,
                    primaryTitle: item.isEnabled ? "Run Menu Item" : "Unavailable Right Now",
                    traits: item.isEnabled ? [] : [.unavailable])))
    }

    private func pressMenuItem(_ itemID: String?, in model: LauncherModel) {
        guard let item = menuSnapshot?.snapshot.items.first(where: { $0.id == itemID }) else {
            model.feedback = .error("That menu item is gone. Search again.")
            return
        }
        guard item.isEnabled else {
            model.feedback = .warning("“\(item.title)” is unavailable in this app right now.")
            return
        }
        // Back in the app first, so the item acts on its window.
        model.panel?.dismiss(restoreFocus: true)
        let search = menuSearch
        let hud = hud
        pendingTask = Task { @MainActor in
            do {
                try await search.press(item)
            } catch {
                hud.show(HUDMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .error))
            }
        }
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        switch scope.id {
        case Self.menuScope.id:
            if !menuSearch.hasPermission {
                return ProvidedEmptyState(
                    title: "Needs Accessibility",
                    detail: "Allow OpenRay in System Settings → Privacy & Security → Accessibility to search menus.",
                    symbol: "lock")
            }
            if isLoading {
                let name = foreground(model)?.name ?? "the app"
                return ProvidedEmptyState(title: "Reading menus…", detail: "Reading \(name)'s menu bar.")
            }
            if let menuError { return ProvidedEmptyState(title: "No menus to search", detail: menuError) }
            return nil
        case Self.volumeScope.id:
            return ProvidedEmptyState(title: "Type a volume", detail: "From 0 to 100, such as 35.", symbol: "speaker.wave.2")
        case Self.outputScope.id, Self.inputScope.id:
            return query.isEmpty
                ? ProvidedEmptyState(title: "No sound devices", detail: "Connect a device, then try again.", symbol: "speaker.slash")
                : nil
        default:
            return nil
        }
    }
}
