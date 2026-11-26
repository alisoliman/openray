import SwiftUI

/// Focus sessions from the launcher: Start Focus Session (type a goal, pick a length), the
/// session commands for hotkeys, and the menu bar timer.
@MainActor
final class FocusCommandProvider: CommandProvider, MenuBarExtraProviding {
    nonisolated static let registration = CommandProviderRegistration(id: "focus", bindablePrefixes: ["focus."]) {
        FocusCommandProvider()
    }

    static let startID = "focus.start"
    static let toggleID = "focus.toggle"
    static let pauseID = "focus.pause"
    static let resumeID = "focus.resume"
    static let snoozeID = "focus.snooze"
    static let completeID = "focus.complete"
    static let menuBarID = "focus.menuBar"
    static let categoriesID = "focus.categories"

    static let startScope = ProvidedScope(
        id: "focus.start", provider: "focus", title: "Start Focus Session", symbol: "scope", kind: .command,
        placeholder: "Your goal, and a length like 40m", summary: "Set a goal and hide distracting apps for a while",
        shortTitle: "Focus", itemNoun: "length", ranksItems: false)

    var id: String { Self.registration.id }
    let controller: FocusController

    init() {
        controller = .shared
    }

    init(controller: FocusController) {
        self.controller = controller
    }

    private func preferences(_ model: LauncherModel) -> FocusPreferences { .load(from: model.store) }
    private func categories(_ model: LauncherModel) -> [FocusCategory] {
        FocusCategory.resolve(model.store.database.focusCategories)
    }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let session = controller.session
        let active = session != nil
        let paused = session?.isPaused == true
        return [
            CommandDescriptor(
                id: Self.startID, title: "Start Focus Session", subtitle: Self.startScope.summary, kind: .command,
                symbol: "scope", keywords: ["focus", "pomodoro", "deep work", "block apps", "timer", "concentrate"],
                mode: .view(.provided(Self.startScope)), showsInRoot: !active),
            CommandDescriptor(
                id: Self.toggleID, title: "Toggle Focus Session",
                subtitle: active ? "Complete the current session" : "Start with your last goal and length", kind: .command,
                symbol: "scope", keywords: ["focus", "start", "stop"], mode: .noView),
            CommandDescriptor(
                id: Self.pauseID, title: "Pause Focus Session", subtitle: "Stop the clock and stop blocking apps",
                kind: .command, symbol: "pause.circle", keywords: ["focus", "break"], mode: .noView,
                showsInRoot: active && !paused, isUnavailable: !active),
            CommandDescriptor(
                id: Self.resumeID, title: "Resume Focus Session", subtitle: "Pick up where you left off", kind: .command,
                symbol: "play.circle", keywords: ["focus", "continue"], mode: .noView, showsInRoot: paused,
                isUnavailable: !paused),
            CommandDescriptor(
                id: Self.snoozeID, title: "Snooze Focus Blocking", subtitle: "Use blocked apps for 5 minutes", kind: .command,
                symbol: "zzz", keywords: ["focus", "allow", "unblock", "break"], mode: .noView, showsInRoot: active,
                isUnavailable: !active),
            CommandDescriptor(
                id: Self.completeID, title: "Complete Focus Session", subtitle: "End the session and see how it went",
                kind: .command, symbol: "checkmark.seal", keywords: ["focus", "stop", "finish", "end"], mode: .noView,
                showsInRoot: active, isUnavailable: !active),
            CommandDescriptor(
                id: Self.categoriesID, title: "Focus Categories", subtitle: "Choose the apps each category holds",
                kind: .command, symbol: "square.grid.2x2", keywords: ["focus", "block list", "allow list", "apps"],
                mode: .noView),
            CommandDescriptor(
                id: Self.menuBarID, title: "Focus Timer in Menu Bar",
                subtitle: "The session's countdown, with pause and snooze", kind: .command, symbol: "menubar.rectangle",
                keywords: ["focus", "menu bar", "timer"], mode: .menuBar, badge: "Menu Bar"),
        ]
    }

    // MARK: Start scope

    /// The lengths offered: the typed one first, then the usual one, then the presets.
    static func lengths(typed: Int?, preferred: Int) -> [Int] {
        var result: [Int] = []
        if let typed { result.append(typed) }
        for minutes in [preferred] + FocusPreferences.presets + [0] where !result.contains(minutes) {
            result.append(minutes)
        }
        return result
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.startScope.id else { return [] }
        if let session = controller.session {
            let left = session.remaining(at: controller.now()).map { "\(FocusFormat.clock($0)) left" } ?? "No time limit"
            return [
                LauncherItem(
                    id: "focus.current", title: "Focusing on \(session.configuration.displayGoal)",
                    subtitle: session.isPaused ? "Paused · \(left)" : left, symbol: "scope", kind: .command, badge: "Focus",
                    action: .provided(
                        ProvidedRef(provider: id, id: "focus.current", primaryTitle: "Complete Session", traits: [])))
            ]
        }
        let preferences = preferences(model)
        let parsed = FocusFormat.parse(query)
        let chosen = categories(model).filter { preferences.categoryIDs.contains($0.id) }
        let what =
            chosen.isEmpty
            ? (preferences.mode == .block ? "Blocking nothing" : "Allowing only system apps")
            : "\(preferences.mode.verb) \(ListFormatter.localizedString(byJoining: chosen.map(\.name)))"
        let goal = parsed.goal
        return Self.lengths(typed: parsed.minutes, preferred: preferences.minutes).map { minutes in
            let title = minutes == 0 ? "Focus with No Time Limit" : "Focus for \(FocusFormat.duration(minutes: minutes))"
            return LauncherItem(
                id: "focus.length.\(minutes)", title: title,
                subtitle: (goal.isEmpty ? "No goal" : goal) + " · " + what, symbol: minutes == 0 ? "infinity" : "timer",
                kind: .command, badge: minutes == parsed.minutes ? "Typed" : (minutes == preferences.minutes ? "Usual" : ""),
                action: .provided(
                    ProvidedRef(
                        provider: id, id: "focus.length.\(minutes)", payload: String(minutes), arguments: ["goal": goal],
                        primaryTitle: "Start Session", traits: [])))
        }
    }

    // MARK: Running

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.toggleID:
            model.store.recordUse(of: item.id)
            if controller.isActive {
                complete(in: model)
            } else {
                let preferences = preferences(model)
                start(goal: preferences.lastGoal, minutes: preferences.minutes, in: model)
            }
        case Self.pauseID: run(model) { try self.controller.pause() } done: { "Focus paused" }
        case Self.resumeID: run(model) { try self.controller.resume() } done: { "Focus resumed" }
        case Self.snoozeID: run(model) { try self.controller.snooze() } done: { "Blocking snoozed for 5 minutes" }
        case Self.completeID, "focus.current": complete(in: model)
        case Self.categoriesID:
            model.store.recordUse(of: item.id)
            model.openSettings(.focus)
        case Self.menuBarID:
            guard let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) else { return }
            MenuBarExtras.toggle(command, provider: self, in: model)
        default:
            guard ref.id.hasPrefix("focus.length."), let minutes = ref.payload.flatMap(Int.init) else { return }
            model.store.recordUse(of: Self.startID)
            start(goal: ref.arguments["goal"] ?? "", minutes: minutes, in: model)
        }
    }

    private func start(goal: String, minutes: Int, in model: LauncherModel) {
        var preferences = preferences(model)
        let configuration = preferences.configuration(goal: goal, minutes: minutes, categories: categories(model))
        do {
            try controller.start(configuration)
        } catch {
            model.feedback = .warning(error.localizedDescription)
            return
        }
        preferences.lastGoal = goal
        if minutes > 0 { preferences.minutes = minutes }
        preferences.save(to: model.store)
        report("Focusing on \(configuration.displayGoal)", in: model)
        model.panel?.dismiss()
    }

    private func complete(in model: LauncherModel) {
        do {
            let summary = try controller.complete()
            report(summary.text, in: model)
        } catch {
            model.feedback = .info(error.localizedDescription)
        }
    }

    private func run(_ model: LauncherModel, _ change: () throws -> Void, done: () -> String) {
        do {
            try change()
            report(done(), in: model)
        } catch {
            model.feedback = .info(error.localizedDescription)
        }
    }

    /// A toast in the panel when it's showing. From a hotkey, the menu bar and the Focus notice
    /// already show the change, so the panel isn't brought up just to say so.
    private func report(_ text: String, in model: LauncherModel) {
        guard model.panel?.isVisible == true else { return }
        model.toast(text)
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.id.hasPrefix("focus.length.") ? "play.fill" : nil
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        if ref.id == Self.menuBarID, let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) {
            return [MenuBarExtras.toggleAction(command, provider: self, in: model)]
        }
        if ref.id == "focus.current" { return sessionActions(in: model) }
        guard ref.id.hasPrefix("focus.length.") else { return [] }
        let preferences = preferences(model)
        var entries: [ActionEntry] = [
            ActionEntry(
                id: "focus.mode", title: preferences.mode == .block ? "Use an Allow List Instead" : "Use a Block List Instead",
                symbol: "arrow.left.arrow.right", shortcut: .command("L", shift: true), key: "l", modifiers: [.command, .shift],
                group: .item
            ) { [weak model] in
                guard let model else { return }
                var preferences = FocusPreferences.load(from: model.store)
                preferences.mode = preferences.mode == .block ? .allow : .block
                preferences.save(to: model.store)
            }
        ]
        for category in categories(model) {
            let on = preferences.categoryIDs.contains(category.id)
            entries.append(
                ActionEntry(
                    id: "focus.category.\(category.id)", title: "\(on ? "Remove" : "Add") \(category.name)",
                    symbol: on ? "checkmark.circle.fill" : category.symbol, group: .organize, section: "Categories"
                ) { [weak model] in
                    guard let model else { return }
                    var preferences = FocusPreferences.load(from: model.store)
                    if on { preferences.categoryIDs.removeAll { $0 == category.id } } else { preferences.categoryIDs.append(category.id) }
                    preferences.save(to: model.store)
                })
        }
        entries.append(
            ActionEntry(id: "focus.editCategories", title: "Edit Categories…", symbol: "gearshape", group: .organize) {
                [weak model] in model?.openSettings(.focus)
            })
        return entries
    }

    private func sessionActions(in model: LauncherModel) -> [ActionEntry] {
        let paused = controller.session?.isPaused == true
        return [
            ActionEntry(
                id: "focus.pauseResume", title: paused ? "Resume" : "Pause", symbol: paused ? "play.fill" : "pause.fill",
                shortcut: .command("P", shift: true), key: "p", modifiers: [.command, .shift], group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.run(model) { try self.controller.togglePause() } done: { paused ? "Focus resumed" : "Focus paused" }
            },
            ActionEntry(id: "focus.snoozeAction", title: "Snooze Blocking for 5 Minutes", symbol: "zzz", group: .item) {
                [weak self, weak model] in
                guard let self, let model else { return }
                self.run(model) { try self.controller.snooze() } done: { "Blocking snoozed for 5 minutes" }
            },
        ]
    }

    // MARK: Menu bar

    func menuBarExtraIsShownByDefault(_ command: CommandDescriptor) -> Bool { command.id == Self.menuBarID }

    func menuBarExtra(for command: CommandDescriptor, in model: LauncherModel) -> MenuBarExtraContent? {
        guard command.id == Self.menuBarID, let session = controller.session, let timer = controller.timerText else { return nil }
        let controller = controller
        let configuration = session.configuration
        let now = controller.now()
        let names = configuration.categoryNames.isEmpty ? "no categories" : configuration.categoryNames.joined(separator: ", ")
        var items: [MenuBarExtraItem] = [
            .label("goal", configuration.displayGoal, symbol: "scope"),
            .label("what", "\(configuration.mode.verb) \(names)"),
        ]
        if case .snoozed(let until) = session.phase, until > now {
            items.append(.label("snoozed", "Blocking snoozed until \(until.formatted(date: .omitted, time: .shortened))"))
        }
        items += [
            .separator("s1"),
            .action("pause", session.isPaused ? "Resume" : "Pause", symbol: session.isPaused ? "play.fill" : "pause.fill") {
                try? controller.togglePause()
            },
            .action("snooze", "Snooze Blocking for 5 Minutes", symbol: "zzz", isEnabled: !session.isSnoozed(at: now)) {
                try? controller.snooze()
            },
            .action("complete", "Complete Session", symbol: "checkmark.seal") { _ = try? controller.complete() },
        ]
        return MenuBarExtraContent(
            title: timer, symbol: session.isPaused ? "pause.circle" : "scope",
            accessibilityLabel: "Focus: \(configuration.displayGoal), \(timer)", items: items, refresh: .seconds(1),
            usesMonospacedDigits: true)
    }
}
