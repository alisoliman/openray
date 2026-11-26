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
    /// The app that was frontmost when the launcher opened or a hotkey ran. Never the window-chip target.
    let foreground: @MainActor (LauncherModel) -> AppIdentity?
    let dismissal: LauncherDismissal
    let menuLimits: MenuItemCollector.Limits
    /// The last command run, so tests can wait for it.
    private(set) var pendingTask: Task<Void, Never>?
    /// This visit's menu items, read when the scope opened and filtered locally after.
    private var menuState: (app: AppIdentity, generation: Int, snapshot: MenuSnapshot)?
    private var menuGeneration = 0
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
            model.foregroundApplication.flatMap { $0.isTerminated ? nil : AppIdentity($0) }
        },
        dismissal: LauncherDismissal = .live(), menuLimits: MenuItemCollector.Limits = .init()
    ) {
        self.executor = executor
        self.audio = audio
        self.menuSearch = menuSearch
        self.hud = hud
        self.foreground = foreground
        self.dismissal = dismissal
        self.menuLimits = menuLimits
    }

    var id: String { Self.providerID }

    func context(in model: LauncherModel) -> SystemCommandContext {
        SystemCommandContext(
            foregroundApplication: foreground(model),
            excludedBundleIdentifiers: Set(model.store.database.keepRunningBundleIDs))
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        // Questions are asked from `perform`, bound to the exact action they describe.
        var descriptors = SystemCommand.all.map { command in
            CommandDescriptor(
                id: command.id.itemID, title: command.title, subtitle: command.subtitle, kind: .system,
                symbol: command.symbol, keywords: command.keywords.split(separator: " ").map(String.init),
                arguments: command.takesArgument
                    ? [ArgumentSpec(name: "level", placeholder: command.argumentPlaceholder ?? "Percent", isOptional: true)]
                    : [],
                // Set Volume asks for its level in its own list, so a hotkey shows it rather than failing.
                mode: command.id == .setVolume ? .view(.provided(Self.volumeScope)) : .noView, badge: "System")
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

    nonisolated static func confirmation(
        _ text: SystemCommand.Confirmation, for id: SystemCommand.ID, context: SystemCommandContext
    ) -> CommandConfirmation {
        // Two apps can share a name; the bundle identifier says which one stays.
        let kept = context.foregroundApplication.map { app in
            "Keeps \(app.name)\(app.bundleIdentifier.map { " (\($0))" } ?? "") running. "
        }
        let detail =
            switch id {
            case .restart, .shutDown, .logOut: "Open apps can ask to save their documents first."
            case .emptyTrash: "This can't be undone."
            case .quitAllApps: "Apps can ask to save first. Apps excluded in Settings › System keep running."
            case .quitAllAppsExceptFrontmost:
                (kept ?? "") + "Apps can ask to save first. Apps excluded in Settings › System keep running."
            case .hideOtherApps: (kept ?? "") + "Unhide All Apps brings the others back."
            default: ""
            }
        // Every system question loses something or affects every app: danger-styled, approved
        // only by a fresh press while the prompt is on screen.
        return CommandConfirmation(question: text.title, detail: detail, confirmTitle: text.button, isDestructive: true)
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
            let context = context(in: model)
            let action: SystemAction
            do {
                switch try command.route(argument: ref.arguments["level"], context: context) {
                case .action(let routed):
                    action = routed
                case .quitApps(let spared):
                    // The one Quit All route: Applications names the exact apps and asks.
                    guard model.applicationsProvider != nil else {
                        model.feedback = .error("\(command.title) needs the Applications commands, which aren't available.")
                        return
                    }
                    model.store.recordUse(of: item.id)
                    model.askToBatch(quitting: true, sparing: spared)
                    return
                }
            } catch {
                // Said in the panel, before it closes: nothing has run.
                model.feedback = .warning(error.localizedDescription)
                return
            }
            guard model.store.database.systemCommandSettings.asksFirst(id), let text = command.confirmation(for: context)
            else {
                model.store.recordUse(of: item.id)
                run(action, reporting: command, in: model)
                return
            }
            // The question names this app and these exclusions. Approval runs exactly this
            // action, and only if neither changed while the question was open.
            model.selectedID = item.id
            model.presentConfirmation(.provided(
                ProvidedConfirmation(id: id.itemID, Self.confirmation(text, for: id, context: context)) {
                    [weak self, weak model] in
                    guard let self, let model else { return }
                    guard self.context(in: model) == context else {
                        model.feedback = .warning(
                            "The app you were using changed while the question was open, so nothing ran. Run \(command.title) again.")
                        return
                    }
                    model.store.recordUse(of: item.id)
                    self.run(action, reporting: command, in: model)
                }))
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
        dismissal.dismiss(model, true)
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
            dismissal.dismiss(model, true)
            hud.show(HUDMessage("\(scope.title): \(device.name)", symbol: device.symbol(for: scope)))
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    // MARK: Search Menu Bar Items

    var providesLiveItems: Bool { true }

    /// Reads the menus once per visit, off the main actor, then filters locally. An empty query
    /// starts a new visit, so a read cancelled by typing never leaves an older snapshot behind.
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        guard scope?.id == Self.menuScope.id else { return [] }
        guard let app = foreground(model) else {
            menuState = nil
            menuError = "Open OpenRay from the app whose menus you want to search."
            return []
        }
        if query.isEmpty || menuState?.app != app {
            menuState = nil
            menuGeneration += 1
            let generation = menuGeneration
            do {
                let snapshot = try await menuSearch.items(for: app.pid, limits: menuLimits)
                guard generation == menuGeneration, !Task.isCancelled else { return [] }
                menuState = (app, generation, snapshot)
                menuError = nil
            } catch is CancellationError {
                return []
            } catch {
                menuError = error.localizedDescription
                return []
            }
        }
        guard !Task.isCancelled, let state = menuState else { return [] }
        return MenuItemSearch.filter(state.snapshot.items, query: query).prefix(100).map {
            menuRow($0, generation: state.generation)
        }
    }

    /// A partial read says so above the rows.
    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.menuScope.id, let state = menuState, !state.snapshot.isComplete else { return nil }
        return [
            LauncherResultGroup(
                id: Self.menuScope.id, title: "Some of \(state.app.name)'s menus weren't read; search to narrow them",
                items: items)
        ]
    }

    private func menuRow(_ item: MenuBarItem, generation: Int) -> LauncherItem {
        LauncherItem(
            id: "system.menu.\(item.id)", title: item.title, subtitle: item.menuText, symbol: "filemenu.and.selection",
            kind: .command, badge: item.shortcut?.joined() ?? "", keywords: item.pathText,
            action: .provided(
                ProvidedRef(
                    provider: id, id: Self.menuRowID, payload: "\(generation)|\(item.id)",
                    primaryTitle: item.isEnabled ? "Run Menu Item" : "Unavailable Right Now",
                    traits: item.isEnabled ? [] : [.unavailable])))
    }

    private func pressMenuItem(_ payload: String?, in model: LauncherModel) {
        let parts = (payload ?? "").split(separator: "|", maxSplits: 1).map(String.init)
        // A row from an earlier read points at menus that may have changed since.
        guard parts.count == 2, let state = menuState, String(state.generation) == parts[0],
            let item = state.snapshot.items.first(where: { $0.id == parts[1] })
        else {
            model.feedback = .error("The menus changed. Search again.")
            return
        }
        guard item.isEnabled else {
            model.feedback = .warning("“\(item.title)” is unavailable in this app right now.")
            return
        }
        // Back in the app first, so the item acts on its window.
        dismissal.dismiss(model, true)
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
