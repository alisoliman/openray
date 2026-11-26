import AppKit
import SwiftUI

/// Window Management through the registry: every window command, the Windows grid's twelve
/// original layouts, exact Move and Resize, Switch Windows, Focus Next/Previous App Window and
/// saved layouts. Every `window.` id has exactly one route: this provider.
@MainActor
final class WindowCommandProvider: CommandProvider {
    nonisolated static let providerID = "windows"
    nonisolated static let registration = CommandProviderRegistration(
        id: providerID, bindablePrefixes: ["window."]
    ) { WindowCommandProvider() }

    /// The Windows grid, in the design system's order: halves, quarters, then the rest.
    /// These keep their mini-screen tiles and their original titles.
    nonisolated static let gridLayouts: [WindowLayout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight,
        .maximize, .center, .nextDisplay, .restore,
    ]

    nonisolated static let layoutPrefix = "window.layout."
    nonisolated static let saveLayoutID = "window.saveLayout"
    nonisolated static let focusNextID = "window.focusNextAppWindow"
    nonisolated static let focusPreviousID = "window.focusPreviousAppWindow"
    nonisolated static let switchID = "window.switch"
    nonisolated static let resizeID = "window.resizeWindow"
    nonisolated static let moveID = "window.moveWindow"
    // Row ids inside the scopes; never commands.
    nonisolated static let switchRowID = "window.switch.row"
    nonisolated static let resizeRowID = "window.resize.row"
    nonisolated static let moveRowID = "window.move.row"

    nonisolated static let switchScope = ProvidedScope(
        id: "window.switch", provider: providerID, title: "Switch Windows", symbol: "macwindow.on.rectangle",
        kind: .window, placeholder: "Search windows by title or app", summary: "Every open window, by title and app",
        shortTitle: "Windows", itemNoun: "window")
    nonisolated static let resizeScope = ProvidedScope(
        id: "window.resize", provider: providerID, title: "Resize Window", symbol: "arrow.up.left.and.arrow.down.right",
        kind: .window, placeholder: "Width × height in points, such as 1200 × 800",
        summary: "An exact size, keeping the top-left corner", itemNoun: "size", ranksItems: false)
    nonisolated static let moveScope = ProvidedScope(
        id: "window.move", provider: providerID, title: "Move Window", symbol: "arrow.up.and.down.and.arrow.left.and.right",
        kind: .window, placeholder: "Left, top in points, such as 100, 50",
        summary: "An exact position from the top left of the display", itemNoun: "position", ranksItems: false)

    nonisolated static func commandID(_ command: WindowCommand) -> String { "window.\(command.rawValue)" }

    nonisolated static func command(forID id: String) -> WindowCommand? {
        guard id.hasPrefix("window.") else { return nil }
        return WindowCommand(rawValue: String(id.dropFirst("window.".count)))
    }

    /// The original layout behind a grid row, for its mini-screen tile.
    nonisolated static func gridLayout(for item: LauncherItem) -> WindowLayout? {
        switch item.action {
        case .window(let layout): return layout
        case .provided(let ref) where ref.provider == providerID:
            return command(forID: ref.id).flatMap { WindowLayout(rawValue: $0.rawValue) }
        default: return nil
        }
    }

    let windows: WindowManager
    let launcher: any ApplicationLaunching
    let hud: HUDController
    /// The app whose focused window commands act on: the one OpenRay opened over, or the one
    /// whose window the target chip chose.
    let foregroundPID: @MainActor (LauncherModel) -> pid_t?
    let dismissal: LauncherDismissal
    let opener: ExternalOpener
    /// Reads Switch Windows' snapshot off the main actor.
    let switchReader: WindowSnapshotReader
    /// The last task started, so tests can wait for it.
    private(set) var pendingTask: Task<Void, Never>?
    /// The running layout. A newer layout cancels it before it can move or close anything else.
    private var layoutTask: Task<Void, Never>?
    /// Switch Windows rows, read once per visit and filtered after.
    private var switchable: [SwitchableWindow] = []

    convenience init() {
        self.init(
            windows: WindowManager(), launcher: WorkspaceApplicationLauncher(), hud: .shared,
            switchReader: WindowSnapshotReader(source: WindowSystemEnvironment.makeSnapshotSource()))
    }

    init(
        windows: WindowManager, launcher: any ApplicationLaunching, hud: HUDController,
        switchReader: WindowSnapshotReader,
        foregroundPID: @escaping @MainActor (LauncherModel) -> pid_t? = { model in
            model.previousApplication.flatMap { $0.isTerminated ? nil : $0.processIdentifier }
        },
        dismissal: LauncherDismissal = .live(), opener: ExternalOpener = .live()
    ) {
        self.windows = windows
        self.launcher = launcher
        self.hud = hud
        self.switchReader = switchReader
        self.foregroundPID = foregroundPID
        self.dismissal = dismissal
        self.opener = opener
    }

    var id: String { Self.providerID }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        // The model refreshes this on show; asking Accessibility on every keystroke would be wasteful.
        let allowed = model.accessibilityAllowed
        let needsAccess = "Needs Accessibility. Press ↩ to enable"
        var descriptors = WindowCommand.allCases.map { command in
            CommandDescriptor(
                id: Self.commandID(command),
                // The grid's twelve keep their original names.
                title: WindowLayout(rawValue: command.rawValue)?.title ?? command.title,
                subtitle: allowed ? "Window layout" : needsAccess, kind: .window, symbol: command.symbol,
                keywords: command.keywords.split(separator: " ").map(String.init) + [command.title.lowercased()],
                mode: .noView, badge: "Window")
        }
        descriptors += [
            CommandDescriptor(
                id: Self.switchID, title: "Switch Windows", subtitle: Self.switchScope.summary, kind: .window,
                symbol: Self.switchScope.symbol, keywords: ["window", "switch", "focus", "tabs", "app"],
                mode: .view(.provided(Self.switchScope))),
            CommandDescriptor(
                id: Self.focusNextID, title: "Focus Next App Window", subtitle: "Cycle through this app's windows",
                kind: .window, symbol: "macwindow.badge.plus", keywords: ["window", "next", "cycle", "focus"],
                mode: .noView, badge: "Window"),
            CommandDescriptor(
                id: Self.focusPreviousID, title: "Focus Previous App Window",
                subtitle: "Cycle back through this app's windows", kind: .window, symbol: "macwindow",
                keywords: ["window", "previous", "cycle", "focus"], mode: .noView, badge: "Window"),
            CommandDescriptor(
                id: Self.resizeID, title: "Resize Window", subtitle: Self.resizeScope.summary, kind: .window,
                symbol: Self.resizeScope.symbol, keywords: ["window", "exact", "size", "width", "height"],
                arguments: [
                    ArgumentSpec(name: "width", placeholder: "Width", isOptional: true),
                    ArgumentSpec(name: "height", placeholder: "Height", isOptional: true),
                ], mode: .view(.provided(Self.resizeScope))),
            CommandDescriptor(
                id: Self.moveID, title: "Move Window", subtitle: Self.moveScope.summary, kind: .window,
                symbol: Self.moveScope.symbol, keywords: ["window", "exact", "position", "move"],
                arguments: [
                    ArgumentSpec(name: "x", placeholder: "Left", isOptional: true),
                    ArgumentSpec(name: "y", placeholder: "Top", isOptional: true),
                ], mode: .view(.provided(Self.moveScope))),
            CommandDescriptor(
                id: Self.saveLayoutID, title: "Save Current Layout",
                subtitle: "Remember the windows on screen as a layout", kind: .window, symbol: "rectangle.3.group",
                keywords: ["window", "layout", "save", "arrangement", "workspace"], mode: .noView, badge: "Window"),
        ]
        descriptors += model.store.database.windowLayouts.map { record in
            CommandDescriptor(
                id: Self.layoutPrefix + record.id.uuidString, title: record.displayName,
                subtitle: record.slots.count == 1 ? "Layout · 1 window" : "Layout · \(record.slots.count) windows",
                kind: .window, symbol: "rectangle.3.group",
                keywords: ["window", "layout", "arrangement"] + record.slots.map(\.appName), mode: .noView,
                badge: "Layout")
        }
        return descriptors
    }

    func primaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        let allowed = model.accessibilityAllowed || windows.hasPermission
        if Self.command(forID: ref.id) != nil { return allowed ? "Apply \(item.title)" : "Enable Accessibility" }
        switch ref.id {
        case Self.switchRowID: return "Switch to Window"
        case Self.resizeRowID: return "Resize Window"
        case Self.moveRowID: return "Move Window"
        case Self.saveLayoutID: return allowed ? "Save Layout" : "Enable Accessibility"
        default: return ref.id.hasPrefix(Self.layoutPrefix) ? (allowed ? "Apply Layout" : "Enable Accessibility") : nil
        }
    }

    // MARK: Perform

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        windows.settings = model.store.database.windowManagementSettings.managerSettings
        if let command = Self.command(forID: ref.id) {
            run(item: item, in: model) { manager, target, pid in
                if let target { try manager.perform(command, on: target) } else {
                    try manager.perform(command, focusedWindowOf: pid)
                }
            }
            return
        }
        switch ref.id {
        case Self.focusNextID, Self.focusPreviousID:
            focusAdjacentWindow(item, forward: ref.id == Self.focusNextID, in: model)
        case Self.switchRowID:
            focusSwitchable(id: ref.payload, in: model)
        case Self.resizeRowID, Self.moveRowID:
            guard let custom = ref.payload.flatMap(Self.customCommand(from:)) else { return }
            run(item: item, in: model) { manager, target, pid in
                if let target { try manager.perform(custom, on: target) } else {
                    try manager.perform(custom, focusedWindowOf: pid)
                }
            }
        case Self.saveLayoutID:
            saveCurrentLayout(item, in: model)
        default:
            if ref.id.hasPrefix(Self.layoutPrefix) { applyLayout(item, ref: ref, in: model) }
        }
    }

    /// Runs a window change on the chosen target window, else the foreground app's focused
    /// window. Success closes the panel; failure stays in it, and a closed target is dropped.
    private func run(
        item: LauncherItem, in model: LauncherModel,
        _ body: (WindowManager, WindowHandle?, pid_t?) throws -> Void
    ) {
        guard requireAccess(in: model) else { return }
        let target = model.targetWindow.map { WindowHandle(pid: $0.pid, element: $0.element) }
        do {
            try body(windows, target, foregroundPID(model))
            model.store.recordUse(of: item.id)
            dismissal.dismiss(model, false)
        } catch {
            // A chosen window that has closed stops being the target.
            if let chosen = model.targetWindow, !windows.listWindows().contains(where: { $0.id == chosen.id }) {
                model.targetWindow = nil
                model.refreshTargetWindow()
            }
            model.feedback = .error(error.localizedDescription)
        }
    }

    private func requireAccess(in model: LauncherModel) -> Bool {
        guard model.accessibilityAllowed || windows.hasPermission else {
            windows.requestPermission()
            _ = opener.open(ExternalOpener.accessibilitySettings)
            model.feedback = .info("Allow OpenRay in Accessibility, then try again.")
            return false
        }
        return true
    }

    // MARK: Layouts

    private func saveCurrentLayout(_ item: LauncherItem, in model: LauncherModel) {
        guard requireAccess(in: model) else { return }
        do {
            let name = Self.nextLayoutName(after: model.store.database.windowLayouts)
            let layout = try windows.captureLayout(named: name)
            guard model.store.update({ $0.windowLayouts.append(WindowLayoutRecord(layout)) }) else {
                model.feedback = .error(model.store.errorMessage ?? "The layout couldn't be saved.")
                return
            }
            model.store.recordUse(of: item.id)
            model.commandCatalogDidChange()
            dismissal.dismiss(model, true)
            let count = layout.slots.count
            hud.show(
                HUDMessage(
                    "Saved “\(name)” with \(count == 1 ? "1 window" : "\(count) windows")", symbol: "rectangle.3.group"))
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    private func applyLayout(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let record = model.store.database.windowLayouts.first(where: { Self.layoutPrefix + $0.id.uuidString == ref.id })
        else {
            model.feedback = .error("This layout no longer exists.")
            return
        }
        do { try record.layout.validate() } catch {
            model.feedback = .warning("\(error.localizedDescription) Edit it in Settings › Windows.")
            return
        }
        guard requireAccess(in: model) else { return }
        guard record.otherWindows == .close else {
            startLayout(record, item: item, in: model)
            return
        }
        // Closing windows the layout doesn't place is never silent. Approval checks the layout
        // again, so an edit made while the question was open can't slip through.
        model.selectedID = item.id
        model.confirmation = .provided(
            ProvidedConfirmation(
                id: ref.id,
                CommandConfirmation(
                    question: "Close other windows?",
                    detail: "“\(record.displayName)” closes the windows it doesn't place on its displays.",
                    confirmTitle: "Apply Layout")
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                guard model.store.database.windowLayouts.first(where: { $0.id == record.id }) == record else {
                    model.feedback = .warning("“\(record.displayName)” changed while the question was open. Run it again.")
                    return
                }
                self.startLayout(record, item: item, in: model)
            })
    }

    private func startLayout(_ record: WindowLayoutRecord, item: LauncherItem, in model: LauncherModel) {
        model.store.recordUse(of: item.id)
        dismissal.dismiss(model, false)
        // One layout at a time: a newer one stops an older one before its next launch, move or close.
        layoutTask?.cancel()
        let layout = record.layout
        let windows = windows
        let launcher = launcher
        let hud = hud
        let task = Task { @MainActor in
            do {
                let outcome = try await windows.apply(layout, launcher: launcher)
                hud.show(
                    HUDMessage(
                        outcome.message, symbol: outcome.isComplete ? "rectangle.3.group" : "exclamationmark.triangle.fill",
                        style: outcome.isComplete ? .success : .warning))
            } catch is CancellationError {
            } catch {
                hud.show(HUDMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .error))
            }
        }
        layoutTask = task
        pendingTask = task
    }

    /// "Layout 1", "Layout 2", … the first number no saved layout uses.
    nonisolated static func nextLayoutName(after records: [WindowLayoutRecord]) -> String {
        let names = Set(records.map(\.displayName))
        var number = records.count + 1
        while names.contains("Layout \(number)") { number += 1 }
        return "Layout \(number)"
    }

    // MARK: Switch Windows

    var providesLiveItems: Bool { true }

    /// Reads every window once per visit, off the main actor and within a time budget, then
    /// filters locally. Leaving the scope or typing cancels a read that's still running.
    func liveItems(for query: String, scope: ProvidedScope?, in model: LauncherModel) async -> [LauncherItem] {
        guard scope?.id == Self.switchScope.id else { return [] }
        if query.isEmpty || switchable.isEmpty {
            switchable = []
            let apps = switchReader.source.applications()
            let primaryHeight = windows.system.displays().first?.frame.maxY ?? 0
            do {
                let read = try await switchReader.windows(of: apps, primaryHeight: primaryHeight)
                guard !Task.isCancelled else { return [] }
                switchable = read
            } catch {
                return []
            }
        }
        return switchable.map(switchRow)
    }

    private func focusAdjacentWindow(_ item: LauncherItem, forward: Bool, in model: LauncherModel) {
        guard requireAccess(in: model) else { return }
        guard let pid = foregroundPID(model), pid != windows.system.ownPID else {
            model.feedback = .warning("Focus a window in another app, then open OpenRay and try again.")
            return
        }
        let current = windows.system.focusedWindow(of: pid)
        let apps = switchReader.source.applications().filter { $0.pid == pid }
        let primaryHeight = windows.system.displays().first?.frame.maxY ?? 0
        model.store.recordUse(of: item.id)
        dismissal.dismiss(model, false)
        let reader = switchReader
        let switcher = WindowSwitcher(system: windows.system, listing: windows.listing)
        let hud = hud
        pendingTask = Task { @MainActor in
            do {
                let list = try await reader.windows(of: apps, primaryHeight: primaryHeight)
                guard let next = WindowSwitcherOrdering.adjacent(in: list, pid: pid, current: current, forward: forward)
                else {
                    hud.show(HUDMessage("This app has no other window", symbol: "macwindow", style: .info))
                    return
                }
                try switcher.focus(next)
            } catch is CancellationError {
            } catch {
                hud.show(HUDMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .error))
            }
        }
    }

    private func switchRow(_ window: SwitchableWindow) -> LauncherItem {
        LauncherItem(
            id: "window.switch.\(window.id)", title: window.title,
            subtitle: window.subtitle.isEmpty ? window.appName : window.subtitle, symbol: "macwindow", kind: .window,
            badge: window.isMinimized ? "Minimized" : "Window", keywords: window.appName, iconURL: window.bundleURL,
            action: .provided(
                ProvidedRef(provider: id, id: Self.switchRowID, payload: window.id, primaryTitle: "Switch to Window", traits: [])))
    }

    private func switchableWindow(id: String?) -> SwitchableWindow? { switchable.first { $0.id == id } }

    private func focusSwitchable(id: String?, in model: LauncherModel) {
        guard let window = switchableWindow(id: id) else {
            model.feedback = .error("That window has closed.")
            return
        }
        do {
            try WindowSwitcher(system: windows.system, listing: windows.listing).focus(window)
            dismissal.dismiss(model, false)
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard ref.id == Self.switchRowID, let window = switchableWindow(id: ref.payload) else { return [] }
        let switcher = WindowSwitcher(system: windows.system, listing: windows.listing)
        func entry(_ id: String, _ title: String, _ symbol: String, destructive: Bool = false,
                   _ body: @escaping @MainActor (WindowSwitcher, SwitchableWindow) throws -> Void) -> ActionEntry {
            ActionEntry(id: "window.\(id)", title: title, symbol: symbol, group: .item, isDestructive: destructive) {
                [weak self, weak model] in
                guard let self, let model else { return }
                do {
                    try body(switcher, window)
                    // Read the list again in the background.
                    self.switchable = []
                    model.refreshProvidedLiveItems()
                } catch {
                    model.feedback = .error(error.localizedDescription)
                }
            }
        }
        return [
            entry("minimize", "Minimize", "minus.rectangle") { try $0.minimize($1) },
            entry("fullscreen", "Toggle Full Screen", "arrow.up.backward.and.arrow.down.forward") {
                try $0.toggleFullScreen($1)
            },
            entry("hide", "Hide \(window.appName)", "eye.slash") { try $0.hideApplication(of: $1) },
            entry("close", "Close Window", "xmark.rectangle", destructive: true) { try $0.close($1) },
        ]
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel)
        -> ProvidedEmptyState?
    {
        switch scope.id {
        case Self.switchScope.id where !windows.hasPermission:
            return ProvidedEmptyState(
                title: "Needs Accessibility",
                detail: "Allow OpenRay in System Settings → Privacy & Security → Accessibility to list windows.",
                symbol: "lock")
        case Self.resizeScope.id:
            return ProvidedEmptyState(
                title: "Type a size", detail: "For example 1200 × 800. The window keeps its top-left corner.",
                symbol: Self.resizeScope.symbol)
        case Self.moveScope.id:
            return ProvidedEmptyState(
                title: "Type a position", detail: "For example 100, 50: points from the display's top left.",
                symbol: Self.moveScope.symbol)
        default:
            return nil
        }
    }

    // MARK: Exact Move and Resize

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        switch scope.id {
        case Self.resizeScope.id:
            let typed =
                query.isEmpty
                ? WindowArgumentParser.pair(scope.arguments["width"], scope.arguments["height"])
                : WindowArgumentParser.pair(query)
            guard let typed, typed.0 > 0, typed.1 > 0 else { return [] }
            let (width, height) = typed
            return [
                LauncherItem(
                    id: "window.resize.\(width)x\(height)",
                    title: "Resize to \(WindowArgumentParser.format(width)) × \(WindowArgumentParser.format(height))",
                    subtitle: "Keeps the window's top-left corner", symbol: Self.resizeScope.symbol, kind: .window,
                    badge: "Window",
                    action: .provided(
                        ProvidedRef(provider: id, id: Self.resizeRowID, payload: "resize:\(width)x\(height)", traits: [])))
            ]
        case Self.moveScope.id:
            let typed =
                query.isEmpty
                ? WindowArgumentParser.pair(scope.arguments["x"], scope.arguments["y"])
                : WindowArgumentParser.pair(query)
            guard let typed else { return [] }
            let (x, y) = typed
            return [
                LauncherItem(
                    id: "window.move.\(x)x\(y)",
                    title: "Move to \(WindowArgumentParser.format(x)), \(WindowArgumentParser.format(y))",
                    subtitle: "From the top left of the window's display", symbol: Self.moveScope.symbol, kind: .window,
                    badge: "Window",
                    action: .provided(ProvidedRef(provider: id, id: Self.moveRowID, payload: "move:\(x)x\(y)", traits: [])))
            ]
        default:
            return []
        }
    }

    /// "resize:1200x800" or "move:100x50" as the exact command.
    nonisolated static func customCommand(from payload: String) -> CustomWindowCommand? {
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let values = WindowArgumentParser.pair(parts[1]) else { return nil }
        let (a, b) = values
        switch parts[0] {
        case "resize": return .resize(width: a, height: b)
        case "move": return .move(x: a, y: b)
        default: return nil
        }
    }
}

/// Reads two numbers typed for exact Move and Resize: "1200x800", "1200 × 800", "100, 50".
/// Values outside what a display could hold are refused before any row is built.
enum WindowArgumentParser {
    /// The same bound `CustomWindowCommand.validate()` applies to points.
    static let limit: Double = 20_000

    static func pair(_ text: String) -> (Double, Double)? {
        let numbers = text.split { "x×X, \t".contains($0) }.map(String.init)
        guard numbers.count == 2 else { return nil }
        return pair(numbers[0], numbers[1])
    }

    static func pair(_ first: String?, _ second: String?) -> (Double, Double)? {
        guard let first = first.flatMap(Double.init), let second = second.flatMap(Double.init),
            first.isFinite, second.isFinite, abs(first) <= limit, abs(second) <= limit
        else { return nil }
        return (first, second)
    }

    /// Whole numbers without a decimal point, fractions to two places. Never traps.
    static func format(_ value: Double) -> String {
        // The parser reads a period, so rows show one too.
        value.formatted(
            .number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
