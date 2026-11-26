import SwiftUI

/// main #11's Caffeinate on the provider architecture. Caffeinate opens a scope with the status
/// and every duration (type a number for minutes); Start, Stop and Toggle act at once and close
/// the launcher, as main's did; the menu bar shows a cup while the Mac is kept awake.
///
/// Slice 5's System commands (Sleep, Lock, Shut Down…) act on the Mac once. Caffeinate holds a
/// power assertion until it's stopped, a timed session ends, or OpenRay quits. No ids collide.
@MainActor
final class CaffeinateCommandProvider: CommandProvider, MenuBarExtraProviding {
    nonisolated static let registration = CommandProviderRegistration(
        id: "caffeinate", bindablePrefixes: ["caffeinate."]
    ) { CaffeinateCommandProvider() }

    /// The ids main's builds stored for favorites, usage and bindings.
    static let openID = "caffeinate.open"
    static let startID = "caffeinate.start"
    static let stopID = "caffeinate.stop"
    static let toggleID = "caffeinate.toggle"
    static let menuBarID = "caffeinate.menuBar"

    // Rows inside the scope.
    static let stopRowID = "caffeinate.row.stop"
    static let customRowID = "caffeinate.row.custom"
    static let settingsRowID = "caffeinate.row.settings"
    static func durationRowID(_ duration: CaffeinateDuration) -> String { "caffeinate.row.\(duration.rawValue)" }

    static let scope = ProvidedScope(
        id: "caffeinate", provider: "caffeinate", title: "Caffeinate", symbol: "cup.and.saucer", kind: .system,
        placeholder: "Choose how long, or type minutes", summary: "Keep your Mac awake", itemNoun: "duration",
        showsPreview: true, ranksItems: false)

    var id: String { Self.registration.id }
    var title: String { "Caffeinate" }

    init() {}

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let caffeinate = model.caffeinate
        let active = caffeinate.isActive
        return [
            CommandDescriptor(
                id: Self.openID, title: "Caffeinate", subtitle: caffeinate.statusText, kind: .system,
                symbol: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                keywords: ["coffee", "caffeine", "awake", "sleep", "duration", "timer", "status"],
                mode: .view(.provided(Self.scope)), badge: active ? "Active" : "Command"),
            CommandDescriptor(
                id: Self.startID, title: "Start Caffeinate", subtitle: "Keep your Mac and display awake indefinitely",
                kind: .system, symbol: "cup.and.saucer.fill",
                keywords: ["coffee", "caffeine", "awake", "prevent sleep", "on"], mode: .noView),
            CommandDescriptor(
                id: Self.stopID, title: "Stop Caffeinate", subtitle: "Let your Mac follow its normal sleep settings",
                kind: .system, symbol: "moon.zzz", keywords: ["coffee", "caffeine", "decaffeinate", "sleep", "off"],
                mode: .noView),
            CommandDescriptor(
                id: Self.toggleID, title: "Toggle Caffeinate",
                subtitle: active ? "Stop keeping your Mac awake" : "Keep your Mac awake indefinitely", kind: .system,
                symbol: "power", keywords: ["coffee", "caffeine", "awake", "sleep", "switch", "on", "off"], mode: .noView,
                badge: active ? "Active" : "Command"),
            CommandDescriptor(
                id: Self.menuBarID, title: "Caffeinate in Menu Bar", subtitle: "A cup while your Mac is kept awake",
                kind: .system, symbol: "menubar.rectangle", keywords: ["caffeinate", "menu bar", "coffee"],
                mode: .menuBar, badge: "Menu Bar"),
        ]
    }

    // MARK: Scope

    /// Minutes typed into the scope's field, when that's all it holds.
    /// A whole number with at most one unit after it: "45", "45m", "45 min", "45 minutes".
    static func typedMinutes(_ query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = trimmed.wholeMatch(of: /(\d{1,5})\s*(m|min|mins|minute|minutes)?/) else { return nil }
        return Int(match.1)
    }

    static func title(for duration: CaffeinateDuration) -> String {
        duration == .indefinitely ? "Keep Awake Indefinitely" : "Keep Awake for \(duration.title)"
    }

    static func minutesTitle(_ minutes: Int) -> String {
        minutes % 60 == 0 && minutes >= 60
            ? "\(minutes / 60) Hour\(minutes == 60 ? "" : "s")" : "\(minutes) Minute\(minutes == 1 ? "" : "s")"
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.scope.id else { return [] }
        let caffeinate = model.caffeinate
        let active = caffeinate.isActive
        var rows: [LauncherItem] = []
        if let minutes = Self.typedMinutes(query) {
            let valid = (1...1_440).contains(minutes)
            rows.append(
                row(
                    Self.customRowID,
                    title: valid ? "Keep Awake for \(Self.minutesTitle(minutes))" : "Enter 1–1,440 minutes",
                    subtitle: valid
                        ? (active ? "Starts a new \(minutes)-minute duration from now" : "Stops on its own")
                        : "Up to 24 hours",
                    symbol: "timer", primary: active ? "Update Duration" : "Start Caffeinate", payload: String(minutes),
                    unavailable: !valid))
        }
        if active {
            let detail = caffeinate.deadline.map { "Stops at \($0.formatted(date: .omitted, time: .shortened))" }
            rows.append(
                row(
                    Self.stopRowID, title: "Stop Caffeinate",
                    subtitle: [caffeinate.statusText, detail].compactMap { $0 }.joined(separator: " · "),
                    symbol: "stop.circle", primary: "Stop Caffeinate"))
        }
        for duration in CaffeinateDuration.allCases {
            rows.append(
                row(
                    Self.durationRowID(duration), title: Self.title(for: duration),
                    subtitle: duration == .indefinitely
                        ? "Until you stop it or quit OpenRay"
                        : (active ? "Starts a new \(duration.title.lowercased()) from now" : "Stops on its own"),
                    symbol: duration == .indefinitely ? "infinity" : "timer",
                    primary: active ? "Update Duration" : "Start Caffeinate", payload: duration.rawValue))
        }
        rows.append(
            row(
                Self.settingsRowID, title: "Caffeinate Settings", subtitle: "A custom duration and the menu bar",
                symbol: "gearshape", primary: "Open Settings"))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, Self.typedMinutes(query) == nil else { return rows }
        return rows.filter { SearchMatcher.score(term, in: $0.title) != nil }
    }

    private func row(
        _ id: String, title: String, subtitle: String, symbol: String, primary: String, payload: String? = nil,
        unavailable: Bool = false
    ) -> LauncherItem {
        LauncherItem(
            id: id, title: title, subtitle: subtitle, symbol: symbol, kind: .system, badge: "",
            action: .provided(
                ProvidedRef(
                    provider: self.id, id: id, payload: payload, primaryTitle: primary,
                    traits: unavailable ? [.unavailable] : [])))
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel) -> ProvidedEmptyState? {
        ProvidedEmptyState(
            title: "No duration matches “\(query)”", detail: "Type a number of minutes, such as 45, or clear the search.")
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard ref.id.hasPrefix("caffeinate.row.") else { return nil }
        return ProvidedPreview(content: AnyView(CaffeinateStatusView(caffeinate: model.caffeinate)))
    }

    // MARK: Running

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        let caffeinate = model.caffeinate
        switch ref.id {
        case Self.startID: finishQuickCommand(item, succeeded: caffeinate.start(), in: model)
        case Self.stopID: finishQuickCommand(item, succeeded: caffeinate.stop(), in: model)
        case Self.toggleID: finishQuickCommand(item, succeeded: caffeinate.toggle(), in: model)
        case Self.stopRowID:
            if caffeinate.stop() {
                model.toast("Caffeinate is off")
            } else {
                model.feedback = .error(caffeinate.errorMessage ?? "Caffeinate couldn't stop. Try again.")
            }
        case Self.customRowID:
            guard let minutes = ref.payload.flatMap(Int.init) else { return }
            start(caffeinate.start(minutes: minutes), title: Self.minutesTitle(minutes).lowercased(), in: model)
        case Self.settingsRowID:
            model.openSettings(.caffeinate)
        case Self.menuBarID:
            guard let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) else { return }
            MenuBarExtras.toggle(command, provider: self, in: model)
        default:
            guard let duration = ref.payload.flatMap(CaffeinateDuration.init(rawValue:)) else { return }
            start(caffeinate.start(for: duration), title: duration.title.lowercased(), in: model)
        }
    }

    /// A duration chosen in the scope: the launcher stays open on the new status, as main's dashboard did.
    private func start(_ succeeded: Bool, title: String, in model: LauncherModel) {
        model.store.recordUse(of: Self.openID)
        if succeeded {
            model.toast(title == "indefinitely" ? "Keeping your Mac awake" : "Keeping your Mac awake for \(title)")
        } else {
            model.feedback = .error(model.caffeinate.errorMessage ?? "Caffeinate couldn't start. Try again.")
        }
    }

    /// Start, Stop and Toggle: on success, record use and close the launcher with a HUD (main closed
    /// it too). On failure the error shows in the panel, which a hotkey then brings up.
    private func finishQuickCommand(_ item: LauncherItem, succeeded: Bool, in model: LauncherModel) {
        guard succeeded else {
            model.feedback = .error(model.caffeinate.errorMessage ?? "Caffeinate couldn't change. Try again.")
            return
        }
        model.store.recordUse(of: item.id)
        let active = model.caffeinate.isActive
        // Handing focus back activates another app, which an inert launch must not do.
        model.panel?.dismiss(restoreFocus: !SideEffectGuard.isInert)
        HUDController.shared.show(
            HUDMessage(
                active ? "Keeping your Mac awake" : "Caffeinate is off",
                symbol: active ? "cup.and.saucer.fill" : "moon.zzz"))
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        switch ref.id {
        case Self.stopRowID: "stop.fill"
        case Self.settingsRowID: nil
        default: ref.id.hasPrefix("caffeinate.row.") ? "play.fill" : nil
        }
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? { nil }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        guard let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) else { return [] }
        if ref.id == Self.menuBarID { return [MenuBarExtras.toggleAction(command, provider: self, in: model)] }
        guard ref.id.hasPrefix("caffeinate.row.") else { return [] }
        var entries: [ActionEntry] = []
        if model.caffeinate.isActive, ref.id != Self.stopRowID {
            entries.append(
                // ⌘. is the launcher's own Stop key; in this scope it stops Caffeinate.
                ActionEntry(
                    id: "caffeinate.stopAction", title: "Stop Caffeinate", symbol: "stop.circle", shortcut: .command("."),
                    group: .item
                ) { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.perform(item, ref: ProvidedRef(provider: self.id, id: Self.stopRowID), in: model)
                })
        }
        entries.append(MenuBarExtras.toggleAction(command, provider: self, in: model))
        if ref.id != Self.settingsRowID {
            entries.append(
                ActionEntry(id: "caffeinate.settings", title: "Caffeinate Settings…", symbol: "gearshape", group: .organize) {
                    [weak model] in model?.openSettings(.caffeinate)
                })
        }
        return entries
    }

    // MARK: Menu bar

    func menuBarExtraIsShownByDefault(_ command: CommandDescriptor) -> Bool { command.id == Self.menuBarID }

    /// A cup while the Mac is kept awake, with its status and controls. Nothing while it's off;
    /// OpenRay's own menu starts a session.
    func menuBarExtra(for command: CommandDescriptor, in model: LauncherModel) -> MenuBarExtraContent? {
        guard command.id == Self.menuBarID, model.caffeinate.isActive else { return nil }
        return MenuBarExtraContent(
            title: nil, symbol: "cup.and.saucer.fill",
            accessibilityLabel: "Caffeinate active. \(model.caffeinate.statusText)",
            items: Self.menuItems(in: model), refresh: model.caffeinate.deadline == nil ? nil : .seconds(1))
    }

    /// Caffeinate's menu: status, Stop, durations and More Options. OpenRay's own menu uses it too.
    static func menuItems(in model: LauncherModel) -> [MenuBarExtraItem] {
        let caffeinate = model.caffeinate
        var items: [MenuBarExtraItem] = []
        if caffeinate.isActive {
            items.append(.label("status", caffeinate.statusText, symbol: "cup.and.saucer.fill"))
            items.append(.action("stop", "Stop Caffeinate", symbol: "stop.circle") { [weak caffeinate] in _ = caffeinate?.stop() })
        }
        items.append(
            .submenu(
                "durations", caffeinate.isActive ? "Keep Awake For…" : "Start Caffeinate", symbol: "timer",
                children: CaffeinateDuration.allCases.map { duration in
                    .action("duration.\(duration.rawValue)", duration.title) { [weak caffeinate] in
                        _ = caffeinate?.start(for: duration)
                    }
                }))
        items.append(
            .action("more", "More Options…", symbol: "slider.horizontal.3") { [weak model] in
                model?.panel?.show(section: .provided(Self.scope))
            })
        if let error = caffeinate.errorMessage { items.append(.label("error", error, symbol: "exclamationmark.triangle")) }
        return items
    }
}

/// Caffeinate's status in the scope's preview pane.
struct CaffeinateStatusView: View {
    let caffeinate: CaffeinateService

    private var tint: Color { caffeinate.isActive ? OR.Color.warning : OR.Color.text3 }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: caffeinate.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: OR.scaled(44), weight: .light)).foregroundStyle(tint)
                .frame(width: 104, height: 104)
                .background(tint.opacity(0.1), in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(caffeinate.isActive ? "Your Mac is awake" : "Ready when you are")
                    .font(OR.Font.title).foregroundStyle(OR.Color.text)
                Text(caffeinate.isActive ? "Your display stays on, too." : "Normal sleep settings apply.")
                    .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 3) {
                    Text(countdown).font(OR.Font.result).foregroundStyle(caffeinate.isActive ? OR.Color.text : OR.Color.text2)
                        .accessibilityIdentifier("caffeinate.countdown")
                    if caffeinate.isActive, let deadline = caffeinate.deadline {
                        Text("Stops at \(deadline.formatted(date: .omitted, time: .shortened))")
                            .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                    } else if caffeinate.isActive {
                        Text("Until you stop it or quit OpenRay").font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Mac and display stay awake", systemImage: "display")
                Label("Stops when you quit OpenRay", systemImage: "power")
                Text("Closing the lid or choosing Sleep can still put your Mac to sleep.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var countdown: String {
        guard caffeinate.isActive else { return "Off" }
        guard let seconds = caffeinate.remainingSeconds else { return "Indefinitely" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
