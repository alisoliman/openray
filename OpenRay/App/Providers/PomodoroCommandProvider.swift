import SwiftUI

/// main #10's Pomodoro on the provider architecture: Pomodoro opens the timer as a scope with a
/// dashboard preview, Start Pomodoro starts or resumes it, and the menu bar shows the countdown.
///
/// Pomodoro and Focus are separate features. Pomodoro paces work in focus and break phases and
/// counts completed sessions; Focus (Slice 6) hides distracting apps for a session. They share no
/// ids, shortcuts or menu bar items, and can run at the same time.
@MainActor
final class PomodoroCommandProvider: CommandProvider, MenuBarExtraProviding {
    nonisolated static let registration = CommandProviderRegistration(id: "pomodoro", bindablePrefixes: ["pomodoro."]) {
        PomodoroCommandProvider()
    }

    /// The ids main's builds stored for favorites, usage and bindings.
    static let openID = "pomodoro.open"
    static let startID = "pomodoro.start"
    static let menuBarID = "pomodoro.menuBar"

    // Rows inside the scope.
    static let primaryRowID = "pomodoro.row.primary"
    static let skipRowID = "pomodoro.row.skipBreak"
    static let resetRowID = "pomodoro.row.reset"
    static let settingsRowID = "pomodoro.row.settings"

    static let scope = ProvidedScope(
        id: "pomodoro", provider: "pomodoro", title: "Pomodoro", symbol: "timer", kind: .command,
        placeholder: "Search Pomodoro", summary: "Focus sessions and breaks", itemNoun: "action", showsPreview: true,
        ranksItems: false)

    var id: String { Self.registration.id }
    var title: String { "Pomodoro" }

    init() {}

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let pomodoro = model.pomodoro
        return [
            CommandDescriptor(
                id: Self.openID, title: "Pomodoro", subtitle: Self.status(of: pomodoro), kind: .command, symbol: "timer",
                keywords: ["focus timer", "productivity", "break", "history", "tomato", "sessions"],
                mode: .view(.provided(Self.scope)),
                badge: pomodoro.state.status == .ready ? "Command" : pomodoro.state.phase.title),
            CommandDescriptor(
                id: Self.startID, title: "Start Pomodoro", subtitle: "Start or resume your focus timer", kind: .command,
                symbol: "play.circle", keywords: ["focus timer", "begin", "resume", "break", "tomato"], mode: .noView),
            CommandDescriptor(
                id: Self.menuBarID, title: "Pomodoro Timer in Menu Bar",
                subtitle: "The countdown while a phase runs, with pause, skip and reset", kind: .command,
                symbol: "menubar.rectangle", keywords: ["pomodoro", "menu bar", "timer", "countdown"], mode: .menuBar,
                badge: "Menu Bar"),
        ]
    }

    /// "Focus · 12:34 left", "Paused · 12:34 left", "Short Break ready", or the call to action.
    static func status(of pomodoro: PomodoroService) -> String {
        let state = pomodoro.state
        switch state.status {
        case .running: return "\(state.phase.title) · \(clock(pomodoro.remainingSeconds)) left"
        case .paused: return "Paused · \(state.phase.title) · \(clock(pomodoro.remainingSeconds)) left"
        case .ready:
            return state.phase == .focus
                ? "Track your focus sessions and breaks" : "\(state.phase.title) ready · \(clock(state.durationSeconds))"
        }
    }

    static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// What the primary control does now.
    static func primaryTitle(_ state: PomodoroState) -> String {
        switch state.status {
        case .ready: state.phase == .focus ? "Start Focus" : "Start \(state.phase.title)"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }

    static func canReset(_ state: PomodoroState) -> Bool {
        state.status != .ready || state.phase != .focus || state.completedInCycle > 0
    }

    // MARK: Scope

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.scope.id else { return [] }
        let pomodoro = model.pomodoro
        let state = pomodoro.state
        var rows: [LauncherItem] = []
        let primary = Self.primaryTitle(state)
        rows.append(
            row(
                Self.primaryRowID, title: primary, subtitle: Self.status(of: pomodoro),
                symbol: state.status == .running ? "pause.fill" : "play.fill", primary: primary))
        if state.phase != .focus {
            rows.append(
                row(
                    Self.skipRowID, title: "Skip Break", subtitle: "Go straight to the next focus session",
                    symbol: "forward.end", primary: "Skip Break"))
        }
        if Self.canReset(state) {
            rows.append(
                row(
                    Self.resetRowID, title: "Reset Cycle",
                    subtitle: "Back to a fresh focus timer. Completed sessions stay in your history.",
                    symbol: "arrow.counterclockwise", primary: "Reset Cycle"))
        }
        rows.append(
            row(
                Self.settingsRowID, title: "Pomodoro Settings",
                subtitle: "Durations, long breaks, daily goal and sound", symbol: "gearshape", primary: "Open Settings"))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return rows }
        return rows.filter { SearchMatcher.score(term, in: $0.title) != nil || SearchMatcher.score(term, in: $0.subtitle) != nil }
    }

    private func row(_ id: String, title: String, subtitle: String, symbol: String, primary: String) -> LauncherItem {
        LauncherItem(
            id: id, title: title, subtitle: subtitle, symbol: symbol, kind: .command, badge: "",
            action: .provided(ProvidedRef(provider: self.id, id: id, primaryTitle: primary, traits: [])))
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel) -> ProvidedEmptyState? {
        ProvidedEmptyState(title: "No Pomodoro action matches “\(query)”", detail: "Clear the search to see the timer.")
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard ref.id.hasPrefix("pomodoro.row.") else { return nil }
        let pomodoro = model.pomodoro
        let configuration = pomodoro.configuration
        return ProvidedPreview(
            content: AnyView(PomodoroDashboard(pomodoro: pomodoro)),
            metadata: [
                ("Focus", "\(configuration.focusMinutes) min"),
                ("Breaks", "\(configuration.shortBreakMinutes) min, long \(configuration.longBreakMinutes) min"),
                ("Long break after", "\(configuration.sessionsBeforeLongBreak) sessions"),
            ])
    }

    // MARK: Running

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        let pomodoro = model.pomodoro
        switch ref.id {
        case Self.startID:
            model.store.recordUse(of: Self.startID)
            let wasRunning = pomodoro.state.status == .running
            pomodoro.start()
            guard report(pomodoro, in: model) else { return }
            if model.panel?.isVisible == true {
                // From the open launcher, show the timer it just started (main #10).
                model.navigate(to: .provided(Self.scope))
            } else {
                // From a hotkey, say so without bringing the launcher up.
                let text =
                    wasRunning
                    ? "\(pomodoro.state.phase.title) is running · \(Self.clock(pomodoro.remainingSeconds)) left"
                    : "\(pomodoro.state.phase.title) started · \(Self.clock(pomodoro.remainingSeconds))"
                HUDController.shared.show(HUDMessage(text, symbol: pomodoro.state.phase.symbol))
            }
        case Self.primaryRowID:
            if pomodoro.state.status == .running { pomodoro.pause() } else { pomodoro.start() }
            _ = report(pomodoro, in: model)
        case Self.skipRowID:
            pomodoro.skipBreak()
            if report(pomodoro, in: model) { model.toast("Break skipped") }
        case Self.resetRowID:
            pomodoro.reset()
            if report(pomodoro, in: model) { model.toast("Cycle reset. Your completed sessions are kept.") }
        case Self.settingsRowID:
            model.openSettings(.pomodoro)
        case Self.menuBarID:
            guard let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) else { return }
            MenuBarExtras.toggle(command, provider: self, in: model)
        default:
            break
        }
    }

    /// Shows a failed save, which leaves the timer as it was. Returns whether it went through.
    private func report(_ pomodoro: PomodoroService, in model: LauncherModel) -> Bool {
        guard let error = pomodoro.errorMessage else { return true }
        model.feedback = .error(error)
        return false
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        ref.id == Self.primaryRowID ? (model.pomodoro.state.status == .running ? "pause.fill" : "play.fill") : nil
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        if ref.id == Self.menuBarID, let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) {
            return [MenuBarExtras.toggleAction(command, provider: self, in: model)]
        }
        guard ref.id.hasPrefix("pomodoro.row.") else { return [] }
        let state = model.pomodoro.state
        var entries: [ActionEntry] = []
        if state.phase != .focus, ref.id != Self.skipRowID {
            entries.append(
                ActionEntry(id: "pomodoro.skipBreak", title: "Skip Break", symbol: "forward.end", group: .item) {
                    [weak self, weak model] in
                    guard let self, let model else { return }
                    self.perform(item, ref: ProvidedRef(provider: self.id, id: Self.skipRowID), in: model)
                })
        }
        if Self.canReset(state), ref.id != Self.resetRowID {
            entries.append(
                ActionEntry(id: "pomodoro.reset", title: "Reset Cycle", symbol: "arrow.counterclockwise", group: .item) {
                    [weak self, weak model] in
                    guard let self, let model else { return }
                    self.perform(item, ref: ProvidedRef(provider: self.id, id: Self.resetRowID), in: model)
                })
        }
        if let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) {
            entries.append(MenuBarExtras.toggleAction(command, provider: self, in: model))
        }
        if ref.id != Self.settingsRowID {
            entries.append(
                ActionEntry(id: "pomodoro.settings", title: "Pomodoro Settings…", symbol: "gearshape", group: .organize) {
                    [weak model] in model?.openSettings(.pomodoro)
                })
        }
        return entries
    }

    // MARK: Menu bar

    func menuBarExtraIsShownByDefault(_ command: CommandDescriptor) -> Bool { command.id == Self.menuBarID }

    /// Shown while a phase runs, is paused, or a break is ready, as main's menu bar label was.
    /// An idle focus timer leaves the menu bar; OpenRay's own menu still starts one.
    func menuBarExtra(for command: CommandDescriptor, in model: LauncherModel) -> MenuBarExtraContent? {
        guard command.id == Self.menuBarID else { return nil }
        let pomodoro = model.pomodoro
        let state = pomodoro.state
        guard state.status != .ready || state.phase != .focus else { return nil }
        let countdown = Self.clock(pomodoro.remainingSeconds)
        let title = state.status == .ready ? "Break" : countdown
        let configuration = pomodoro.configuration
        var items: [MenuBarExtraItem] = [
            .label("phase", "\(state.phase.title) · \(Self.statusTitle(state.status))", symbol: state.phase.symbol)
        ]
        items.append(
            .action(
                "primary", Self.primaryTitle(state), symbol: state.status == .running ? "pause.fill" : "play.fill"
            ) { [weak pomodoro] in
                guard let pomodoro else { return }
                if pomodoro.state.status == .running { pomodoro.pause() } else { pomodoro.start() }
            })
        if state.phase != .focus {
            items.append(.action("skip", "Skip Break", symbol: "forward.end") { [weak pomodoro] in pomodoro?.skipBreak() })
        }
        if Self.canReset(state) {
            items.append(
                .action("reset", "Reset Cycle", symbol: "arrow.counterclockwise") { [weak pomodoro] in pomodoro?.reset() })
        }
        items += [
            .separator("s1"),
            .label(
                "today",
                "Today: \(pomodoro.completedToday)/\(configuration.dailyGoal) sessions · \(pomodoro.focusMinutesToday) min"),
            .action("open", "Open Pomodoro", symbol: "timer") { [weak model] in
                model?.panel?.show(section: .provided(Self.scope))
            },
        ]
        if let error = pomodoro.errorMessage { items.append(.label("error", error, symbol: "exclamationmark.triangle")) }
        let spoken =
            state.status == .ready
            ? "Pomodoro, \(state.phase.title) ready"
            : "Pomodoro, \(state.phase.title), \(countdown), \(Self.statusTitle(state.status))"
        return MenuBarExtraContent(
            title: title, symbol: state.status == .paused ? "pause.circle" : "timer", accessibilityLabel: spoken,
            items: items, refresh: state.status == .running ? .seconds(1) : nil, usesMonospacedDigits: true)
    }

    static func statusTitle(_ status: PomodoroStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .running: "In progress"
        case .paused: "Paused"
        }
    }
}

/// The timer in the scope's preview pane: phase, countdown ring, cycle, today and recent sessions.
struct PomodoroDashboard: View {
    let pomodoro: PomodoroService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: PomodoroState { pomodoro.state }
    private var configuration: PomodoroConfiguration { pomodoro.configuration }
    private var tint: Color { state.phase == .focus ? OR.Color.accent : OR.Color.success }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(state.phase.title, systemImage: state.phase.symbol)
                        .font(OR.Font.calloutEmphasis).foregroundStyle(tint)
                    Spacer()
                    Text(PomodoroCommandProvider.statusTitle(state.status))
                        .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                }
                ring.frame(maxWidth: .infinity)
                cycle
                today
                history
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ring: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ZStack {
                Circle().stroke(OR.Color.fill2, lineWidth: 7)
                Circle().trim(from: 0, to: min(1, max(0, pomodoro.progress)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text(PomodoroCommandProvider.clock(pomodoro.remainingSeconds))
                        .font(OR.Font.result).foregroundStyle(OR.Color.text)
                        .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    Text(caption).font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                }
            }
            .frame(width: 150, height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(state.phase.title) timer")
            .accessibilityValue(
                "\(pomodoro.remainingSeconds / 60) minutes, \(pomodoro.remainingSeconds % 60) seconds remaining. \(PomodoroCommandProvider.statusTitle(state.status))"
            )
            .accessibilityIdentifier("pomodoro.countdown")
        }
    }

    private var caption: String {
        switch state.status {
        case .ready: "Ready when you are"
        case .running: state.phase == .focus ? "Focus on one thing" : "Take a moment to recharge"
        case .paused: "Take your time"
        }
    }

    private var cycle: some View {
        HStack(spacing: 6) {
            ForEach(0..<configuration.sessionsBeforeLongBreak, id: \.self) { index in
                Circle().fill(index < state.completedInCycle ? tint : OR.Color.fill3).frame(width: 7, height: 7)
            }
            Text("\(state.completedInCycle) / \(configuration.sessionsBeforeLongBreak) this cycle")
                .font(OR.Font.caption).foregroundStyle(OR.Color.text2).padding(.leading, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(state.completedInCycle) of \(configuration.sessionsBeforeLongBreak) focus sessions completed this cycle")
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today").font(OR.Font.sectionHeader).foregroundStyle(OR.Color.text2)
            HStack(spacing: 18) {
                metric("\(pomodoro.completedToday)", "sessions")
                metric("\(pomodoro.focusMinutesToday)", "focus minutes")
            }
            ProgressView(value: min(Double(pomodoro.completedToday) / Double(configuration.dailyGoal), 1))
                .tint(OR.Color.accentFill)
                .accessibilityLabel("Daily focus goal")
                .accessibilityValue("\(pomodoro.completedToday) of \(configuration.dailyGoal) sessions")
            Text(
                pomodoro.completedToday >= configuration.dailyGoal
                    ? "Daily goal reached. Well done."
                    : "\(configuration.dailyGoal - pomodoro.completedToday) more to your daily goal of \(configuration.dailyGoal)"
            )
            .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(OR.Font.display).monospacedDigit().foregroundStyle(OR.Color.text)
            Text(label).font(OR.Font.caption).foregroundStyle(OR.Color.text2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent focus sessions").font(OR.Font.sectionHeader).foregroundStyle(OR.Color.text2)
            if pomodoro.recentSessions.isEmpty {
                Text("Completed focus sessions appear here. Breaks and unfinished sessions don't count toward your goal.")
                    .font(OR.Font.caption).foregroundStyle(OR.Color.text3).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(pomodoro.recentSessions) { session in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(OR.Color.success)
                            .accessibilityHidden(true)
                        Text("\(session.durationSeconds / 60) min of focus").foregroundStyle(OR.Color.text)
                        Spacer(minLength: 4)
                        Text(session.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(OR.Color.text3)
                    }
                    .font(OR.Font.caption)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
