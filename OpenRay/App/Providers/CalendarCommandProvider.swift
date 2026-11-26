import SwiftUI

/// My Schedule: upcoming events in a scope, the next meeting in root search, and the calendar
/// actions (join, open, email guests, block time, copy availability).
@MainActor
final class CalendarCommandProvider: CommandProvider, MenuBarExtraProviding {
    nonisolated static let registration = CommandProviderRegistration(id: "calendar", bindablePrefixes: ["calendar."]) {
        CalendarCommandProvider()
    }

    static let scheduleID = "calendar.schedule"
    static let blockTimeID = "calendar.blockTime"
    static let availabilityID = "calendar.copyAvailability"
    static let joinNextID = "calendar.joinNext"
    static let menuBarID = "calendar.menuBar"
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    static let scope = ProvidedScope(
        id: "calendar.schedule", provider: "calendar", title: "My Schedule", symbol: "calendar", kind: .command,
        placeholder: "Search events", summary: "Upcoming events from your calendars", shortTitle: "Schedule",
        itemNoun: "event", showsPreview: true, ranksItems: false)

    var id: String { Self.registration.id }
    let service: CalendarService

    init() {
        service = .shared
    }

    init(service: CalendarService) {
        self.service = service
    }

    private func preferences(_ model: LauncherModel) -> CalendarPreferences { .load(from: model.store) }

    // MARK: Commands

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let access = service.access
        let refused = access == .denied || access == .restricted
        let noAccess = "Allow calendar access in System Settings first"
        let days = preferences(model).availability.days
        return [
            CommandDescriptor(
                id: Self.scheduleID, title: "My Schedule", subtitle: Self.scope.summary, kind: .command, symbol: "calendar",
                keywords: ["calendar", "events", "meetings", "agenda", "today"], mode: .view(.provided(Self.scope))),
            CommandDescriptor(
                id: Self.joinNextID, title: "Join Next Meeting", subtitle: refused ? noAccess : "Open the next call link",
                kind: .command, symbol: "video", keywords: ["calendar", "zoom", "meet", "teams", "webex", "call"],
                mode: .noView, isUnavailable: refused),
            CommandDescriptor(
                id: Self.blockTimeID, title: "Block Time", subtitle: refused ? noAccess : "Reserve the next free slot on your calendar",
                kind: .command, symbol: "calendar.badge.plus", keywords: ["calendar", "focus", "busy", "reserve", "hold"],
                arguments: [
                    ArgumentSpec(name: "title", placeholder: "Focus Time", isOptional: true, defaultValue: "Focus Time"),
                    ArgumentSpec(
                        name: "duration", placeholder: "Length",
                        type: .dropdown([
                            .init(title: "30 minutes", value: "30"), .init(title: "1 hour", value: "60"),
                            .init(title: "90 minutes", value: "90"), .init(title: "2 hours", value: "120"),
                        ]), isOptional: true, defaultValue: "60"),
                ],
                mode: .noView, isUnavailable: refused),
            CommandDescriptor(
                id: Self.availabilityID, title: "Copy Availability",
                subtitle: refused ? noAccess : "Your free time over the next working days, ready to paste", kind: .command,
                symbol: "calendar.day.timeline.left", keywords: ["calendar", "free", "slots", "schedule", "meeting times"],
                arguments: [
                    ArgumentSpec(
                        name: "days", placeholder: "Days",
                        type: .dropdown([1, 3, 5, 7, 10].map { .init(title: "\($0) day\($0 == 1 ? "" : "s")", value: "\($0)") }),
                        isOptional: true, defaultValue: "\(days)")
                ],
                mode: .noView, isUnavailable: refused),
            CommandDescriptor(
                id: Self.menuBarID, title: "Next Event in Menu Bar",
                subtitle: "A countdown to your next meeting in the menu bar", kind: .command, symbol: "menubar.rectangle",
                keywords: ["calendar", "menu bar", "countdown", "meeting"], mode: .menuBar, badge: "Menu Bar"),
        ]
    }

    // MARK: Rows

    private func event(withID id: String) -> CalendarEvent? { service.events.first { $0.id == id } }

    /// An event as a row. `place` is “root”, “now” (the first event after the now line) or “scope”.
    func item(for event: CalendarEvent, place: String) -> LauncherItem {
        let link = event.meetingLink
        let root = place == "root"
        let time = service.timeRange(of: event)
        let when = root ? "\(CalendarService.relativeStart(of: event, now: service.now())) · \(time)" : time
        let detail = link?.provider.title ?? event.location.flatMap { $0.isEmpty ? nil : $0 }
        let guests = event.attendees.map(\.displayName).joined(separator: " ")
        return LauncherItem(
            id: "calendar.event.\(event.id)", title: event.title, subtitle: [when, detail].compactMap { $0 }.joined(separator: " · "),
            symbol: link == nil ? "calendar" : "video", kind: .command, badge: root ? "Next Event" : event.calendarTitle,
            keywords: "meeting event calendar schedule next join \(event.location ?? "") \(event.calendarTitle) \(guests)",
            action: .provided(
                ProvidedRef(
                    provider: id, id: event.id, payload: place, copyText: link?.url.absoluteString,
                    primaryTitle: root && link != nil ? "Join Meeting" : "Open in Calendar", traits: [])))
    }

    func rootItems(for query: String, in model: LauncherModel) -> [LauncherItem] {
        guard !query.isEmpty, service.access.canRead else { return [] }
        if service.isStale { Task { @MainActor [service] in service.refresh() } }
        let preferences = preferences(model)
        guard let event = service.nextEventForRoot(leadMinutes: preferences.rootLeadMinutes, hidden: preferences.hiddenCalendarIDs)
        else { return [] }
        return [item(for: event, place: "root")]
    }

    func scopeItems(_ scope: ProvidedScope, query: String, in model: LauncherModel) -> [LauncherItem] {
        guard scope.id == Self.scope.id else { return [] }
        let access = service.access
        // Asked once, the first time My Schedule opens.
        if access == .notDetermined, !service.didRequestAccess {
            Task { @MainActor [service] in await service.requestAccessIfNeeded() }
        } else if !access.canRead, access != .unavailable {
            Task { @MainActor [service] in service.updateAccess() }
        }
        switch access {
        case .notDetermined:
            return [
                accessRow(
                    "calendar.access.request", title: "Allow Access to Calendars",
                    subtitle: "OpenRay reads your events on this Mac to show your schedule. Nothing leaves your Mac.",
                    symbol: "calendar.badge.checkmark")
            ]
        case .denied, .restricted, .writeOnly:
            return [
                accessRow(
                    "calendar.access.settings", title: "Turn On Calendar Access",
                    subtitle: "Open Privacy & Security › Calendars and allow OpenRay full access.", symbol: "lock.shield")
            ]
        case .unavailable:
            return []
        case .fullAccess:
            if service.isStale { Task { @MainActor [service] in service.refresh() } }
            let preferences = preferences(model)
            let now = service.now()
            let start = service.calendar.startOfDay(for: now)
            var events = service.upcoming(after: start, hidden: preferences.hiddenCalendarIDs)
            if !query.isEmpty {
                events = events.filter { event in
                    [event.title, event.location ?? "", event.calendarTitle, event.attendees.map(\.displayName).joined(separator: " ")]
                        .contains { $0.localizedCaseInsensitiveContains(query) }
                }
            }
            // The now line sits above the first event today that hasn't ended.
            let nowLineID =
                query.isEmpty
                ? events.first { !$0.hasEnded(at: now) && service.calendar.isDate($0.start, inSameDayAs: now) }?.id : nil
            return events.map { item(for: $0, place: $0.id == nowLineID ? "now" : "scope") }
        }
    }

    private func accessRow(_ rowID: String, title: String, subtitle: String, symbol: String) -> LauncherItem {
        LauncherItem(
            id: rowID, title: title, subtitle: subtitle, symbol: symbol, kind: .permission, badge: "Calendar",
            action: .provided(ProvidedRef(provider: id, id: rowID, payload: "access", primaryTitle: title, traits: [])))
    }

    func scopeGroups(_ scope: ProvidedScope, items: [LauncherItem], in model: LauncherModel) -> [LauncherResultGroup]? {
        guard scope.id == Self.scope.id else { return nil }
        let access = items.filter { if case .provided(let ref) = $0.action { ref.payload == "access" } else { false } }
        if !access.isEmpty { return [LauncherResultGroup(id: "calendar.access", title: nil, items: access)] }
        let tile = GridTileRenderer { [weak self, weak model] item, selected in
            guard let self, case .provided(let ref) = item.action, let event = self.event(withID: ref.id) else {
                return AnyView(StandardGridTile(item: item))
            }
            let now = self.service.now()
            var join: (() -> Void)?
            if event.meetingLink != nil, !event.hasEnded(at: now), let model {
                join = { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.join(event, in: model)
                }
            }
            return AnyView(
                CalendarEventRow(
                    event: event, timeRange: self.service.timeRange(of: event), now: now, showsNowLine: ref.payload == "now",
                    selected: selected, onJoin: join))
        }
        var groups: [(key: String, title: String, trailing: String?, items: [LauncherItem])] = []
        let now = service.now()
        for item in items {
            guard case .provided(let ref) = item.action, let event = event(withID: ref.id) else { continue }
            let section = Self.section(for: event.start, now: now, calendar: service.calendar)
            if groups.last?.key == section.key {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((section.key, section.title, section.trailing, [item]))
            }
        }
        return groups.map {
            LauncherResultGroup(
                id: "calendar.\($0.key)", title: $0.title, trailing: $0.trailing, style: .grid, items: $0.items, columns: 1,
                tile: tile)
        }
    }

    /// The heading an event's day falls under: Today, Tomorrow, a weekday this week, Next Week,
    /// Later in <month>, then one heading per month.
    static func section(for date: Date, now: Date, calendar: Calendar) -> (key: String, title: String, trailing: String?) {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        let dayFormatter = formatter("EEE MMM d")
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if offset <= 0 { return ("today", "Today", dayFormatter.string(from: date)) }
        if offset == 1 { return ("tomorrow", "Tomorrow", dayFormatter.string(from: date)) }
        // Half-open: DateInterval.contains counts the end, which is next week's first midnight.
        func within(_ interval: DateInterval?) -> Bool { interval.map { $0.start <= day && day < $0.end } ?? false }
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
        if within(thisWeek) {
            return ("day.\(offset)", formatter("EEEE").string(from: date), dayFormatter.string(from: date))
        }
        if let thisWeek, within(calendar.dateInterval(of: .weekOfYear, for: thisWeek.end)) {
            return ("nextWeek", "Next Week", nil)
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .month) {
            return ("laterThisMonth", "Later in \(formatter("MMMM").string(from: date))", nil)
        }
        let components = calendar.dateComponents([.year, .month], from: date)
        return ("month.\(components.year ?? 0).\(components.month ?? 0)", formatter("MMMM yyyy").string(from: date), nil)
    }

    func emptyState(for scope: ProvidedScope, query: String, isLoading: Bool, in model: LauncherModel) -> ProvidedEmptyState? {
        guard scope.id == Self.scope.id else { return nil }
        switch service.access {
        case .unavailable:
            return ProvidedEmptyState(
                title: "Calendars aren't read here",
                detail: "OpenRay doesn't read your calendars in tests or isolated verification mode.", symbol: "calendar")
        case .fullAccess where query.isEmpty:
            return ProvidedEmptyState(
                title: "Nothing scheduled", detail: "No events in the next four weeks in the calendars you include.",
                symbol: "calendar")
        default:
            return nil
        }
    }

    // MARK: Running

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        switch ref.id {
        case Self.joinNextID:
            model.store.recordUse(of: item.id)
            joinNext(in: model)
        case Self.blockTimeID:
            model.store.recordUse(of: item.id)
            blockTime(in: model, title: ref.arguments["title"], minutes: ref.arguments["duration"].flatMap(Int.init))
        case Self.availabilityID:
            model.store.recordUse(of: item.id)
            copyAvailability(in: model, days: ref.arguments["days"].flatMap(Int.init))
        case Self.menuBarID:
            guard let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) else { return }
            MenuBarExtras.toggle(command, provider: self, in: model)
        case "calendar.access.request":
            Task { @MainActor [service] in
                await service.requestAccessIfNeeded()
                if service.access == .notDetermined { service.updateAccess() }
            }
        case "calendar.access.settings":
            open(Self.privacySettingsURL, in: model)
        default:
            guard let event = event(withID: ref.id) else {
                model.feedback = .warning("This event is no longer on your calendar.")
                return
            }
            if ref.payload == "root", event.meetingLink != nil {
                join(event, in: model)
            } else {
                openInCalendar(event, in: model)
            }
        }
    }

    func primarySymbol(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard let event = event(withID: ref.id) else { return nil }
        return ref.payload == "root" && event.meetingLink != nil ? "video" : "calendar"
    }

    func secondaryTitle(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> String? {
        guard let event = event(withID: ref.id), event.meetingLink != nil else { return nil }
        return ref.payload == "root" ? "Open in Calendar" : "Join Meeting"
    }

    func performSecondary(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let event = event(withID: ref.id), event.meetingLink != nil else { return }
        if ref.payload == "root" { openInCalendar(event, in: model) } else { join(event, in: model) }
    }

    func actions(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> [ActionEntry] {
        if ref.id == Self.menuBarID, let command = commands(in: model).first(where: { $0.id == Self.menuBarID }) {
            return [MenuBarExtras.toggleAction(command, provider: self, in: model)]
        }
        guard let event = event(withID: ref.id) else { return [] }
        var entries: [ActionEntry] = []
        if let link = event.meetingLink {
            entries.append(
                ActionEntry(
                    id: "calendar.copyLink", title: "Copy Join Link", symbol: "link", shortcut: .command("C", shift: true),
                    key: "c", modifiers: [.command, .shift], group: .item
                ) { [weak model] in model?.copy(link.url.absoluteString, label: "\(link.provider.title) link") })
        }
        if event.myStatus == .pending {
            entries.append(
                ActionEntry(
                    id: "calendar.respond", title: "Accept or Decline in Calendar…", symbol: "checkmark.circle",
                    shortcut: KeyShortcut(["⌃", "A"]), key: "a", modifiers: [.control], group: .item
                ) { [weak self, weak model] in
                    guard let self, let model else { return }
                    // EventKit can't answer invitations, so Calendar does.
                    self.openInCalendar(event, in: model)
                })
        }
        if !event.emailableAttendees.isEmpty {
            entries.append(
                ActionEntry(
                    id: "calendar.email", title: "Email Attendees", symbol: "envelope", shortcut: .command("E", shift: true),
                    key: "e", modifiers: [.command, .shift], group: .item
                ) { [weak self, weak model] in
                    guard let self, let model, let url = CalendarService.mailtoURL(for: event) else { return }
                    self.open(url, in: model)
                })
        }
        entries.append(
            ActionEntry(
                id: "calendar.copyDetails", title: "Copy Event Details", symbol: "doc.on.doc", shortcut: .command("."),
                key: ".", modifiers: [.command], group: .item
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                model.copy(self.service.details(of: event), label: event.title)
            })
        entries.append(
            ActionEntry(
                id: "calendar.blockTime", title: "Block Time…", symbol: "calendar.badge.plus",
                shortcut: .command("B", shift: true), key: "b", modifiers: [.command, .shift], group: .organize
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.blockTime(in: model, title: nil, minutes: nil)
            })
        entries.append(
            ActionEntry(
                id: "calendar.copyAvailability", title: "Copy Availability", symbol: "calendar.day.timeline.left",
                shortcut: KeyShortcut(["⌃", "⌥", "A"]), key: "a", modifiers: [.control, .option], group: .organize
            ) { [weak self, weak model] in
                guard let self, let model else { return }
                self.copyAvailability(in: model, days: nil)
            })
        return entries
    }

    func preview(for item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) -> ProvidedPreview? {
        guard let event = event(withID: ref.id) else { return nil }
        let date = event.start.formatted(date: .complete, time: .omitted)
        var metadata: [(label: String, value: String)] = [
            ("When", "\(date), \(service.timeRange(of: event))"), ("Calendar", event.calendarTitle),
        ]
        if let location = event.location, !location.isEmpty { metadata.append(("Location", location)) }
        if let link = event.meetingLink { metadata.append(("Call", link.provider.title)) }
        if let status = event.myStatus { metadata.append(("Your answer", status.rawValue.capitalized)) }
        return ProvidedPreview(content: AnyView(CalendarEventPreview(event: event)), metadata: metadata)
    }

    // MARK: Actions

    func join(_ event: CalendarEvent, in model: LauncherModel) {
        do {
            try service.join(event)
            model.panel?.dismiss(restoreFocus: false)
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    func openInCalendar(_ event: CalendarEvent, in model: LauncherModel) {
        do {
            try service.openInCalendar(event)
            model.panel?.dismiss(restoreFocus: false)
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    private func open(_ url: URL, in model: LauncherModel) {
        do {
            try service.opener.open(url)
            model.panel?.dismiss(restoreFocus: false)
        } catch {
            model.feedback = .error(error.localizedDescription)
        }
    }

    func joinNext(in model: LauncherModel) {
        guard service.access.canRead else {
            model.feedback = .warning("Open My Schedule to allow calendar access first.")
            return
        }
        service.refreshIfStale()
        let preferences = preferences(model)
        guard let event = service.nextEventForMenuBar(leadMinutes: 60, onlyMeetings: true, hidden: preferences.hiddenCalendarIDs)
        else {
            model.feedback = .info("No meeting with a call link in the next hour.")
            return
        }
        join(event, in: model)
    }

    /// Asks, then adds an event in the next free slot of the length chosen. Nothing is offered
    /// when no working-hours slot is free, and the slot is checked again when the person confirms.
    func blockTime(in model: LauncherModel, title: String?, minutes: Int?) {
        service.updateAccess()
        guard service.access == .fullAccess else {
            model.feedback = .warning("Open My Schedule to allow calendar access first.")
            return
        }
        let name = title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? title! : "Focus Time"
        proposeBlock(minutes: minutes ?? 60, name: name, in: model, retry: false)
    }

    private func proposeBlock(minutes: Int, name: String, in model: LauncherModel, retry: Bool) {
        // Always from events read just now: what was cached can be minutes old, and a failed
        // read can't vouch for any time.
        do { try service.refreshVerified() } catch {
            model.feedback = .warning(error.localizedDescription)
            return
        }
        let preferences = preferences(model)
        let length = FocusFormat.duration(minutes: minutes)
        guard
            let slot = service.nextFreeSlot(
                lasting: TimeInterval(minutes * 60), options: preferences.availability, hidden: preferences.hiddenCalendarIDs)
        else {
            model.feedback = .info("There's no free \(length) in your working hours over the next 7 working days.")
            return
        }
        let when = Self.describe(slot, now: service.now(), calendar: service.calendar)
        let question = CommandConfirmation(
            question: retry ? "That time is no longer free. Block \(length) \(when) instead?" : "Block \(length) \(when)?",
            detail: "Adds “\(name)” to your default calendar.", confirmTitle: "Block Time", symbol: "calendar.badge.plus")
        model.confirmation = .provided(
            ProvidedConfirmation(id: "calendar.blockTime.confirm", question) { [weak self, weak model] in
                guard let self, let model else { return }
                // The calendar, the clock and access can all change while the question is up, so
                // the time is checked again on events read just now.
                do { try self.service.refreshVerified() } catch {
                    model.feedback = .warning(error.localizedDescription)
                    return
                }
                let current = self.preferences(model)
                guard self.service.isBookable(slot, options: current.availability, hidden: current.hiddenCalendarIDs) else {
                    self.proposeBlock(minutes: minutes, name: name, in: model, retry: true)
                    return
                }
                do {
                    _ = try self.service.createEvent(title: name, interval: slot)
                    model.toast("Blocked \(when)")
                } catch {
                    model.feedback = .error(error.localizedDescription)
                }
            })
    }

    /// “today, 2:15 – 3:15 PM” or “Fri, Nov 27, 9:00 – 10:00 AM”.
    static func describe(_ slot: DateInterval, now: Date, calendar: Calendar) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let range = formatter.string(from: slot) ?? ""
        if calendar.isDate(slot.start, inSameDayAs: now) { return "today, \(range)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(slot.start, inSameDayAs: tomorrow) {
            return "tomorrow, \(range)"
        }
        return "\(slot.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), \(range)"
    }

    func copyAvailability(in model: LauncherModel, days: Int?) {
        var preferences = preferences(model)
        if let days { preferences.availability.days = days }
        do {
            let text = try service.availabilityText(options: preferences.availability, hidden: preferences.hiddenCalendarIDs)
            let count = preferences.availability.days
            if model.copy(text, label: "Availability") {
                model.toast("Copied your availability for the next \(count) working day\(count == 1 ? "" : "s")")
            }
        } catch {
            model.feedback = .warning(
                service.access.canRead ? error.localizedDescription : "Open My Schedule to allow calendar access first.")
        }
    }

    // MARK: Menu bar

    /// While nothing is soon enough to show, wake when the next meeting enters its countdown, and
    /// at least every five minutes for new events.
    func menuBarExtraIdleRefresh(for command: CommandDescriptor, in model: LauncherModel) -> Duration? {
        guard command.id == Self.menuBarID, service.access.canRead else { return nil }
        let preferences = preferences(model)
        let now = service.now()
        let lead = TimeInterval(preferences.menuBarLeadMinutes * 60)
        let next = service.upcoming(after: now, hidden: preferences.hiddenCalendarIDs).first { event in
            !event.isAllDay && (!preferences.menuBarOnlyMeetings || event.meetingLink != nil)
        }
        let wait = next.map { max(1, $0.start.timeIntervalSince(now) - lead) } ?? 300
        return .seconds(min(wait, 300).rounded(.up))
    }

    func menuBarExtra(for command: CommandDescriptor, in model: LauncherModel) -> MenuBarExtraContent? {
        guard command.id == Self.menuBarID, service.access.canRead else { return nil }
        if service.isStale { Task { @MainActor [service] in service.refresh() } }
        let preferences = preferences(model)
        guard
            let event = service.nextEventForMenuBar(
                leadMinutes: preferences.menuBarLeadMinutes, onlyMeetings: preferences.menuBarOnlyMeetings,
                hidden: preferences.hiddenCalendarIDs)
        else { return nil }
        let now = service.now()
        let short = event.title.count > 22 ? String(event.title.prefix(20)) + "…" : event.title
        let relative = CalendarService.relativeStart(of: event, now: now)
        var items: [MenuBarExtraItem] = [
            .label("title", event.title, symbol: event.meetingLink == nil ? "calendar" : "video"),
            .label("time", "\(service.timeRange(of: event)) · \(relative)"),
            .separator("s1"),
        ]
        if event.meetingLink != nil {
            items.append(.action("join", "Join Meeting", symbol: "video") { [weak self, weak model] in
                guard let self, let model else { return }
                self.join(event, in: model)
            })
        }
        items.append(.action("open", "Open in Calendar", symbol: "calendar") { [weak self, weak model] in
            guard let self, let model else { return }
            self.openInCalendar(event, in: model)
        })
        items.append(.action("schedule", "Open My Schedule", symbol: "list.bullet.below.rectangle") { [weak model] in
            model?.panel?.show(section: .provided(Self.scope))
        })
        items.append(.separator("s2"))
        items.append(.action("hide", "Remove from Menu Bar", symbol: "menubar.arrow.down.rectangle") { [weak model] in
            guard let model else { return }
            MenuBarExtras.setShown(false, commandID: Self.menuBarID, in: model.store)
        })
        return MenuBarExtraContent(
            title: "\(short) · \(relative.lowercased())", symbol: event.meetingLink == nil ? "calendar" : "video",
            accessibilityLabel: "\(event.title), \(relative)", items: items, refresh: .seconds(30))
    }
}

// MARK: - Views

/// The calendar event row from the design gaps: the calendar's color, the time range, the
/// title, a Join button when there's a call link, and the now line above the next event.
struct CalendarEventRow: View {
    let event: CalendarEvent
    var timeRange: String
    var now: Date
    var showsNowLine: Bool
    var selected: Bool
    var onJoin: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsNowLine {
                HStack(spacing: 6) {
                    Circle().fill(OR.Color.danger).frame(width: 7, height: 7)
                    Rectangle().fill(OR.Color.danger).frame(height: 1.5)
                    Text("Now · \(now.formatted(date: .omitted, time: .shortened))").font(OR.Font.caption)
                        .foregroundStyle(OR.Color.danger).fixedSize()
                }
                .accessibilityLabel("Now")
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(timeRange).font(OR.Font.caption).monospacedDigit().foregroundStyle(OR.Color.text2)
                        if event.isOngoing(at: now) {
                            Text("Now").font(OR.Font.caption).foregroundStyle(OR.Color.accent)
                                .padding(.horizontal, 5).frame(height: 16)
                                .background(OR.Color.accentSoft, in: .capsule)
                        }
                    }
                    Text(event.title).font(OR.Font.rowTitle).foregroundStyle(OR.Color.text).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(OR.Font.caption).foregroundStyle(OR.Color.text3).lineLimit(1)
                }
                if let onJoin {
                    Button("Join", action: onJoin)
                        .buttonStyle(.or(.primary))
                        .controlSize(.small)
                        .highPriorityGesture(TapGesture().onEnded { onJoin() })
                        .accessibilityLabel("Join \(event.meetingLink?.provider.title ?? "") meeting")
                }
            }
        }
        .padding(.horizontal, 6)
        .opacity(event.hasEnded(at: now) ? 0.5 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var color: Color {
        event.calendarColor.map { Color(hex: $0) } ?? OR.Color.accent
    }

    private var detail: String? {
        if let link = event.meetingLink { return link.provider.title }
        if let location = event.location, !location.isEmpty { return location }
        return nil
    }
}

/// The preview pane's top: guests and notes.
struct CalendarEventPreview: View {
    let event: CalendarEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(event.title).font(OR.Font.title).foregroundStyle(OR.Color.text)
                if !event.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Guests").font(OR.Font.sectionHeader).foregroundStyle(OR.Color.text2)
                        ForEach(Array(event.attendees.prefix(12).enumerated()), id: \.offset) { _, attendee in
                            HStack(spacing: 6) {
                                Image(systemName: symbol(for: attendee.status)).foregroundStyle(OR.Color.text3)
                                    .accessibilityLabel(attendee.status.rawValue)
                                Text(attendee.displayName).foregroundStyle(OR.Color.text)
                            }
                            .font(OR.Font.callout)
                        }
                        if event.attendees.count > 12 {
                            Text("and \(event.attendees.count - 12) more").font(OR.Font.callout).foregroundStyle(OR.Color.text3)
                        }
                    }
                }
                if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Text(notes).font(OR.Font.callout).foregroundStyle(OR.Color.text2).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(for status: CalendarAttendee.Status) -> String {
        switch status {
        case .accepted: "checkmark.circle"
        case .declined: "xmark.circle"
        case .tentative: "questionmark.circle"
        case .pending, .unknown: "circle"
        }
    }
}
