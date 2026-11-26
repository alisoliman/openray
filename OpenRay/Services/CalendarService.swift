import AppKit
@preconcurrency import EventKit
import Foundation
import Observation

// MARK: - Values

struct CalendarAttendee: Hashable, Sendable {
    enum Status: String, Hashable, Sendable { case accepted, declined, tentative, pending, unknown }
    var name: String?
    var email: String?
    var status: Status = .unknown
    var isCurrentUser = false

    var displayName: String { name?.isEmpty == false ? name! : email ?? "Guest" }
}

/// One occurrence of an event. Recurring events share an `eventIdentifier`, so `id` adds the start.
struct CalendarEvent: Identifiable, Hashable, Sendable {
    var id: String
    var eventIdentifier: String
    var externalIdentifier: String?
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var location: String?
    var notes: String?
    var url: URL?
    var calendarID: String = ""
    var calendarTitle: String = ""
    /// The calendar's color as 0xRRGGBB.
    var calendarColor: UInt32?
    var attendees: [CalendarAttendee] = []
    var organizer: String?
    /// How the calendar marks the event's time.
    var availability: EventAvailability = .unspecified

    init(
        id: String? = nil, eventIdentifier: String = UUID().uuidString, externalIdentifier: String? = nil,
        title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, notes: String? = nil,
        url: URL? = nil, calendarID: String = "", calendarTitle: String = "", calendarColor: UInt32? = nil,
        attendees: [CalendarAttendee] = [], organizer: String? = nil, availability: EventAvailability = .unspecified
    ) {
        self.id = id ?? "\(eventIdentifier)@\(Int(start.timeIntervalSince1970))"
        self.eventIdentifier = eventIdentifier
        self.externalIdentifier = externalIdentifier
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor
        self.attendees = attendees
        self.organizer = organizer
        self.availability = availability
    }

    var meetingLink: MeetingLink? { MeetingLink.detect(url: url, location: location, notes: notes) }

    /// Whether the event takes its time, for availability and Block Time. A timed event does
    /// unless it's marked Free. An all-day event does only when marked Busy or Unavailable, since
    /// most all-day entries (holidays, birthdays, reminders) don't hold the day.
    var blocksTime: Bool {
        isAllDay ? availability == .busy || availability == .unavailable : availability != .free
    }

    func overlaps(_ interval: DateInterval) -> Bool { start < interval.end && end > interval.start }

    /// The person's own answer, when they're invited rather than organizing.
    var myStatus: CalendarAttendee.Status? { attendees.first(where: \.isCurrentUser)?.status }

    /// Guests with an email address, without the person themselves.
    var emailableAttendees: [CalendarAttendee] {
        attendees.filter { !$0.isCurrentUser && $0.email?.contains("@") == true }
    }

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
    func hasEnded(at now: Date) -> Bool { end <= now }
}

/// How an event's time is marked, as EventKit reports it.
enum EventAvailability: String, Hashable, Sendable {
    case busy, free, tentative, unavailable
    /// The calendar doesn't say, such as a subscribed holiday calendar.
    case unspecified
}

/// A calendar the person can include or leave out of My Schedule.
struct CalendarInfo: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var source: String
    var color: UInt32?
}

enum CalendarAccess: Equatable, Sendable {
    case notDetermined, denied, restricted, fullAccess, writeOnly
    /// The launch doesn't allow calendar access at all: tests and verification mode.
    case unavailable

    var canRead: Bool { self == .fullAccess }
}

// MARK: - Meeting links

/// A video call link in an event, and the service it belongs to.
struct MeetingLink: Hashable, Sendable {
    enum Provider: String, CaseIterable, Hashable, Sendable {
        case zoom, googleMeet, teams, webex

        var title: String {
            switch self {
            case .zoom: "Zoom"
            case .googleMeet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .webex: "Webex"
            }
        }
    }

    var provider: Provider
    var url: URL

    private static let tail = #"[^\s<>"'\]\)]*"#
    private static let patterns: [(Provider, NSRegularExpression)] = [
        (.zoom, #"zoommtg://[^\s<>"']+"#),
        (.zoom, #"https?://(?:[\w-]+\.)*zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s|wc/join)/"# + tail),
        (.googleMeet, #"https?://meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3}"# + tail),
        // Work and school links, long (meetup-join) and short (meet/<id>?p=<passcode>), including
        // the government clouds, then personal ones. The query, with its passcode, is kept.
        (.teams, #"https?://(?:[\w-]+\.)*teams\.microsoft\.(?:com|us)/(?:l/meetup-join/|meet/)"# + tail),
        (.teams, #"https?://teams\.live\.com/meet/"# + tail),
        (.webex, #"https?://(?:[\w-]+\.)*webex\.com/(?:meet|join|[\w-]+/j\.php|wbxmjs|webappng)"# + tail),
    ].map { provider, pattern in (provider, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) }

    /// The first call link in one piece of text.
    static func detect(in text: String?) -> MeetingLink? {
        guard let text, !text.isEmpty else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        var best: (location: Int, link: MeetingLink)?
        for (provider, pattern) in patterns {
            guard let match = pattern.firstMatch(in: text, range: range) else { continue }
            var string = (text as NSString).substring(with: match.range)
            // Sentence punctuation after a link isn't part of it.
            while let last = string.last, ".,;:!?".contains(last) { string.removeLast() }
            guard let url = URL(string: string) else { continue }
            if best == nil || match.range.location < best!.location {
                best = (match.range.location, MeetingLink(provider: provider, url: url))
            }
        }
        return best?.link
    }

    /// The event's call link: its URL field first, then its location, then its notes.
    static func detect(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        detect(in: url?.absoluteString) ?? detect(in: location) ?? detect(in: notes)
    }
}

// MARK: - Availability

/// Free time between events, for Copy Availability and Block Time.
enum Availability {
    struct Options: Equatable, Sendable {
        /// Working days to cover, starting today.
        var days = 3
        /// The working day, in minutes after midnight.
        var dayStart = 9 * 60
        var dayEnd = 17 * 60
        /// Shorter gaps aren't offered.
        var minimumMinutes = 30
        var skipsWeekends = true
    }

    /// The working days the options cover, starting with today when it's one.
    static func days(from now: Date, options: Options, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: now)
        var guardCount = 0
        while result.count < max(1, options.days), guardCount < 60 {
            if !(options.skipsWeekends && calendar.isDateInWeekend(day)) { result.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardCount += 1
        }
        return result
    }

    /// Free slots on each working day, from now on, at least `minimumMinutes` long.
    static func freeSlots(
        events: [CalendarEvent], from now: Date, options: Options, calendar: Calendar
    ) -> [(day: Date, slots: [DateInterval])] {
        let busy = events.filter(\.blocksTime).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            .sorted { $0.start < $1.start }
        return days(from: now, options: options, calendar: calendar).map { day in
            guard let open = wallClock(options.dayStart, on: day, calendar: calendar),
                let close = wallClock(options.dayEnd, on: day, calendar: calendar), close > open
            else { return (day, []) }
            var cursor = max(open, roundedUp(now, toMinutes: 15, calendar: calendar))
            var slots: [DateInterval] = []
            for interval in busy where interval.end > cursor && interval.start < close {
                if interval.start > cursor { slots.append(DateInterval(start: cursor, end: min(interval.start, close))) }
                cursor = max(cursor, interval.end)
                if cursor >= close { break }
            }
            if cursor < close { slots.append(DateInterval(start: cursor, end: close)) }
            let minimum = TimeInterval(options.minimumMinutes * 60)
            return (day, slots.filter { $0.duration >= minimum })
        }
    }

    /// The first free slot of at least `duration`, starting no earlier than now.
    static func firstSlot(
        lasting duration: TimeInterval, events: [CalendarEvent], from now: Date, options: Options, calendar: Calendar
    ) -> DateInterval? {
        var options = options
        options.minimumMinutes = Int(duration / 60)
        options.days = max(options.days, 7)
        for (_, slots) in freeSlots(events: events, from: now, options: options, calendar: calendar) {
            if let slot = slots.first { return DateInterval(start: slot.start, duration: duration) }
        }
        return nil
    }

    /// `minutes` after midnight as a local wall-clock time on `day`, so the working day keeps its
    /// hours across a daylight-saving change. 24:00 is the next midnight.
    static func wallClock(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        guard minutes < 1_440 else { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) }
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    /// True when `interval` falls inside one working day's hours, on a day the options cover.
    static func isWithinWorkingHours(_ interval: DateInterval, options: Options, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: interval.start)
        guard !(options.skipsWeekends && calendar.isDateInWeekend(day)),
            let open = wallClock(options.dayStart, on: day, calendar: calendar),
            let close = wallClock(options.dayEnd, on: day, calendar: calendar)
        else { return false }
        return interval.start >= open && interval.end <= close
    }

    /// True when no event that takes its time overlaps `interval`.
    static func isFree(_ interval: DateInterval, events: [CalendarEvent]) -> Bool {
        !events.contains { $0.blocksTime && $0.overlaps(interval) }
    }

    static func roundedUp(_ date: Date, toMinutes step: Int, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.minute, .second, .nanosecond], from: date)
        let minute = components.minute ?? 0
        let extra = (step - minute % step) % step
        let hasSeconds = (components.second ?? 0) > 0 || (components.nanosecond ?? 0) > 0
        let add = extra == 0 && hasSeconds ? step : extra
        guard let base = calendar.date(bySetting: .second, value: 0, of: date) else { return date }
        let trimmed = calendar.date(bySetting: .nanosecond, value: 0, of: base) ?? base
        // date(bySetting:) can move forward to the next match; never go before the original.
        let start = trimmed > date ? calendar.date(byAdding: .minute, value: -1, to: trimmed) ?? trimmed : trimmed
        return calendar.date(byAdding: .minute, value: add, to: start) ?? date
    }

    /// One line per day, ready to paste into a message:
    /// `Thu, Nov 26: 9:00 – 10:30 AM, 1:00 – 5:00 PM`.
    static func format(
        _ days: [(day: Date, slots: [DateInterval])], dayLabel: (Date) -> String, range: (DateInterval) -> String,
        timeZoneName: String?
    ) -> String {
        var lines = days.map { day, slots in
            "\(dayLabel(day)): " + (slots.isEmpty ? "no free time" : slots.map(range).joined(separator: ", "))
        }
        if let timeZoneName { lines.insert("My availability (\(timeZoneName)):", at: 0) }
        return lines.joined(separator: "\n")
    }

    /// `format` with the person's locale and time zone.
    static func formatted(_ days: [(day: Date, slots: [DateInterval])], calendar: Calendar, locale: Locale = .current) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = locale
        dayFormatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        let intervalFormatter = DateIntervalFormatter()
        intervalFormatter.calendar = calendar
        intervalFormatter.timeZone = calendar.timeZone
        intervalFormatter.locale = locale
        intervalFormatter.dateStyle = .none
        intervalFormatter.timeStyle = .short
        return format(
            days, dayLabel: { dayFormatter.string(from: $0) }, range: { intervalFormatter.string(from: $0) ?? "" },
            timeZoneName: calendar.timeZone.localizedName(for: .shortGeneric, locale: locale))
    }
}

// MARK: - Preferences

/// Calendar settings, kept in `commandPreferences["pref.calendar"]` so the library schema doesn't change.
struct CalendarPreferences: Equatable, Sendable {
    static let storageKey = "pref.calendar"

    /// Root search shows the next event from this many minutes before it starts until this many after.
    var rootLeadMinutes = 10
    /// The menu bar item counts down from this many minutes before an event.
    var menuBarLeadMinutes = 60
    /// Only events with a call link in the menu bar.
    var menuBarOnlyMeetings = true
    /// Calendars left out of My Schedule, by id. Empty includes every calendar.
    var hiddenCalendarIDs: Set<String> = []
    var availability = Availability.Options()

    static let leadChoices = [2, 5, 10, 15, 30]

    init() {}

    init(_ values: [String: String]) {
        if let value = values["rootLead"].flatMap(Int.init), (0...120).contains(value) { rootLeadMinutes = value }
        if let value = values["menuBarLead"].flatMap(Int.init), (0...1_440).contains(value) { menuBarLeadMinutes = value }
        if let value = values["menuBarOnlyMeetings"] { menuBarOnlyMeetings = value != "false" }
        if let value = values["hiddenCalendars"], !value.isEmpty {
            hiddenCalendarIDs = Set(value.split(separator: "\n").map(String.init))
        }
        if let value = values["availabilityDays"].flatMap(Int.init), (1...14).contains(value) { availability.days = value }
        if let value = values["dayStart"].flatMap(Int.init), (0..<1_440).contains(value) { availability.dayStart = value }
        if let value = values["dayEnd"].flatMap(Int.init), (1...1_440).contains(value) { availability.dayEnd = value }
        if let value = values["skipWeekends"] { availability.skipsWeekends = value != "false" }
    }

    var values: [String: String] {
        [
            "rootLead": String(rootLeadMinutes), "menuBarLead": String(menuBarLeadMinutes),
            "menuBarOnlyMeetings": String(menuBarOnlyMeetings),
            "hiddenCalendars": hiddenCalendarIDs.sorted().joined(separator: "\n"),
            "availabilityDays": String(availability.days), "dayStart": String(availability.dayStart),
            "dayEnd": String(availability.dayEnd), "skipWeekends": String(availability.skipsWeekends),
        ]
    }

    @MainActor
    static func load(from store: LibraryStore) -> CalendarPreferences {
        CalendarPreferences(store.database.commandPreferences[storageKey] ?? [:])
    }

    @MainActor
    @discardableResult
    func save(to store: LibraryStore) -> Bool {
        store.update { $0.commandPreferences[Self.storageKey] = values }
    }
}

// MARK: - Side effects

/// Where calendar data comes from. The live source is EventKit; tests use a fake.
@MainActor
protocol CalendarEventSource: AnyObject {
    var access: CalendarAccess { get }
    /// Asks macOS for full calendar access. Only ever called when the person opens My Schedule.
    func requestAccess() async -> CalendarAccess
    func calendars() -> [CalendarInfo]
    func events(from start: Date, to end: Date) throws -> [CalendarEvent]
    /// Adds an event to the default calendar.
    func createEvent(title: String, start: Date, end: Date) throws -> CalendarEvent
    /// Called when the calendar database changes outside OpenRay.
    var onChange: (@MainActor () -> Void)? { get set }
}

/// Opens links: call links, `mailto:`, the calendar app.
@MainActor
protocol URLOpening: AnyObject {
    func open(_ url: URL) throws
}

/// The live opener. Refused in tests and verification mode.
@MainActor
final class WorkspaceURLOpener: URLOpening {
    let guardrail: SideEffectGuard
    init(guardrail: SideEffectGuard = .current) { self.guardrail = guardrail }

    func open(_ url: URL) throws {
        try guardrail.check("opening \(url.scheme ?? "a link")")
        guard NSWorkspace.shared.open(url) else {
            throw CalendarServiceError.couldNotOpen(url.scheme ?? "link")
        }
    }
}

enum CalendarServiceError: LocalizedError, Equatable {
    case noAccess, noDefaultCalendar, couldNotOpen(String), couldNotRead
    var errorDescription: String? {
        switch self {
        case .noAccess: "OpenRay doesn't have access to your calendars."
        case .couldNotRead: "OpenRay couldn't read your calendars to check that time."
        case .noDefaultCalendar: "There's no default calendar for new events."
        case .couldNotOpen(let what): "OpenRay couldn't open this \(what) link."
        }
    }
}

/// EventKit, behind the guard. Nothing here runs in tests or verification mode: access reads
/// as `.unavailable` and every call throws before touching EventKit.
@MainActor
final class EventKitCalendarSource: CalendarEventSource {
    let guardrail: SideEffectGuard
    var onChange: (@MainActor () -> Void)?
    private var store: EKEventStore?
    private var observer: NSObjectProtocol?

    init(guardrail: SideEffectGuard = .current) {
        self.guardrail = guardrail
    }

    private func eventStore() throws -> EKEventStore {
        try guardrail.check("reading your calendars")
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        return store
    }

    var access: CalendarAccess {
        // The stricter of the injected and the process rule.
        guard !guardrail.effective.isInert else { return .unavailable }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        guard (try? guardrail.check("requesting calendar access")) != nil, let store = try? eventStore() else {
            return .unavailable
        }
        _ = try? await store.requestFullAccessToEvents()
        return access
    }

    func calendars() -> [CalendarInfo] {
        guard access.canRead, let store = try? eventStore() else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, color: Self.hex($0.color))
        }
        .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func events(from start: Date, to end: Date) throws -> [CalendarEvent] {
        guard access.canRead else { throw CalendarServiceError.noAccess }
        let store = try eventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.event(from:)).sorted { $0.start < $1.start }
    }

    func createEvent(title: String, start: Date, end: Date) throws -> CalendarEvent {
        try guardrail.check("adding a calendar event")
        guard access == .fullAccess || access == .writeOnly else { throw CalendarServiceError.noAccess }
        let store = try eventStore()
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarServiceError.noDefaultCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        event.availability = .busy
        try store.save(event, span: .thisEvent, commit: true)
        return Self.event(from: event)
    }

    private static func event(from event: EKEvent) -> CalendarEvent {
        let attendees = (event.attendees ?? []).map { participant in
            CalendarAttendee(
                name: participant.name, email: email(from: participant.url), status: status(participant.participantStatus),
                isCurrentUser: participant.isCurrentUser)
        }
        return CalendarEvent(
            eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
            externalIdentifier: event.calendarItemExternalIdentifier, title: event.title ?? "Untitled Event",
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, location: event.location,
            notes: event.notes, url: event.url, calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "", calendarColor: event.calendar.flatMap { hex($0.color) },
            attendees: attendees, organizer: event.organizer?.name, availability: availability(event.availability))
    }

    private static func email(from url: URL) -> String? {
        let string = url.absoluteString
        guard string.lowercased().hasPrefix("mailto:") else { return nil }
        return String(string.dropFirst("mailto:".count)).removingPercentEncoding
    }

    private static func availability(_ availability: EKEventAvailability) -> EventAvailability {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        default: .unspecified
        }
    }

    private static func status(_ status: EKParticipantStatus) -> CalendarAttendee.Status {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
    }

    private static func hex(_ color: NSColor?) -> UInt32? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return red << 16 | green << 8 | blue
    }
}

// MARK: - Service

/// My Schedule's data: access, a cache of upcoming events, and the actions on them. Reads are
/// cheap and synchronous from the cache, so root search and the scope can ask on every keystroke;
/// refreshes run when the cache is stale or the calendar database changes.
@MainActor
@Observable
final class CalendarService {
    static let shared = CalendarService(source: EventKitCalendarSource(), opener: WorkspaceURLOpener())

    @ObservationIgnored let source: any CalendarEventSource
    @ObservationIgnored let opener: any URLOpening
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored var calendar: Calendar
    /// How far ahead My Schedule looks.
    @ObservationIgnored var lookahead: TimeInterval = 28 * 86_400
    /// The cache is refreshed when older than this.
    @ObservationIgnored var maximumAge: TimeInterval = 120

    private(set) var access: CalendarAccess
    /// Events from the start of today through `lookahead`, every calendar.
    private(set) var events: [CalendarEvent] = []
    private(set) var lastRefresh: Date?
    private(set) var isRequestingAccess = false
    /// Set once access was asked for in this launch, so My Schedule asks only once.
    private(set) var didRequestAccess = false
    private(set) var lastError: String?

    init(
        source: any CalendarEventSource, opener: any URLOpening, now: @escaping () -> Date = { .now },
        calendar: Calendar = .current
    ) {
        self.source = source
        self.opener = opener
        self.now = now
        self.calendar = calendar
        access = source.access
        source.onChange = { [weak self] in
            self?.lastRefresh = nil
            self?.refresh()
        }
    }

    // MARK: Access

    /// Asks for access the first time My Schedule opens, never before.
    func requestAccessIfNeeded() async {
        updateAccess()
        guard access == .notDetermined, !didRequestAccess, !isRequestingAccess else { return }
        isRequestingAccess = true
        didRequestAccess = true
        access = await source.requestAccess()
        isRequestingAccess = false
        if access.canRead { refresh() }
    }

    /// Re-reads access, for when the person changed it in System Settings. Assigns only on a
    /// change, so views that call it while drawing don't redraw for nothing.
    func updateAccess() {
        let current = source.access
        if current != access { access = current }
    }

    // MARK: Events

    var isStale: Bool { lastRefresh.map { now().timeIntervalSince($0) > maximumAge } ?? true }

    /// Reloads the cache from the source.
    func refresh() {
        do { try refreshVerified() } catch {
            if !access.canRead, !events.isEmpty { events = [] }
        }
    }

    /// Reloads the cache, and throws when it can't: no read access (write-only included), or
    /// the read failed. Block Time decides only on events read just now.
    func refreshVerified() throws {
        updateAccess()
        guard access.canRead else { throw CalendarServiceError.noAccess }
        let start = calendar.startOfDay(for: now())
        do {
            events = try source.events(from: start, to: start.addingTimeInterval(lookahead))
            lastError = nil
            lastRefresh = now()
        } catch {
            lastError = error.localizedDescription
            throw CalendarServiceError.couldNotRead
        }
    }

    func refreshIfStale() {
        if isStale { refresh() }
    }

    /// Cached events in the calendars the person includes, that end after `from`.
    func upcoming(after from: Date? = nil, hidden: Set<String> = []) -> [CalendarEvent] {
        let cutoff = from ?? now()
        return events.filter { $0.end > cutoff && !hidden.contains($0.calendarID) }.sorted {
            $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
        }
    }

    /// The event root search offers: from `lead` minutes before it starts until `lead` minutes
    /// after, timed events only, earliest first.
    func nextEventForRoot(leadMinutes: Int, hidden: Set<String> = []) -> CalendarEvent? {
        let now = now()
        let lead = TimeInterval(leadMinutes * 60)
        return upcoming(after: now, hidden: hidden).first { event in
            !event.isAllDay && event.start.addingTimeInterval(-lead) <= now && now <= event.start.addingTimeInterval(lead)
        }
    }

    /// The next timed event within `leadMinutes`, or the one in progress, for the menu bar.
    func nextEventForMenuBar(leadMinutes: Int, onlyMeetings: Bool, hidden: Set<String> = []) -> CalendarEvent? {
        let now = now()
        return upcoming(after: now, hidden: hidden).first { event in
            !event.isAllDay && (!onlyMeetings || event.meetingLink != nil)
                && event.start <= now.addingTimeInterval(TimeInterval(leadMinutes * 60))
        }
    }

    // MARK: Actions

    func join(_ event: CalendarEvent) throws {
        guard let link = event.meetingLink else { throw CalendarServiceError.couldNotOpen("meeting") }
        try opener.open(link.url)
    }

    /// Shows the event in Calendar. Answering invites happens there too, since EventKit can't.
    func openInCalendar(_ event: CalendarEvent) throws {
        if let url = Self.calendarURL(for: event), (try? opener.open(url)) != nil { return }
        try opener.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    static func calendarURL(for event: CalendarEvent) -> URL? {
        let identifier = event.eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.eventIdentifier
        return URL(string: "ical://ekevent/\(identifier)?method=show&options=more")
    }

    /// `mailto:` every guest, with the event's title as the subject.
    static func mailtoURL(for event: CalendarEvent) -> URL? {
        let addresses = event.emailableAttendees.compactMap(\.email)
        guard !addresses.isEmpty else { return nil }
        // Encoded by hand: URLComponents leaves “&” in a query value, which would end the subject.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let to = addresses.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "@+"))) ?? $0 }
        let subject = event.title.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: "mailto:\(to.joined(separator: ","))?subject=\(subject)")
    }

    func emailAttendees(of event: CalendarEvent) throws {
        guard let url = Self.mailtoURL(for: event) else { throw CalendarServiceError.couldNotOpen("email") }
        try opener.open(url)
    }

    func createEvent(title: String, interval: DateInterval) throws -> CalendarEvent {
        let event = try source.createEvent(title: title, start: interval.start, end: interval.end)
        lastRefresh = nil
        refresh()
        return event
    }

    /// Free time over the next working days, as text to paste.
    func availabilityText(options: Availability.Options, hidden: Set<String> = []) throws -> String {
        updateAccess()
        guard access.canRead else { throw CalendarServiceError.noAccess }
        let start = calendar.startOfDay(for: now())
        let horizon = start.addingTimeInterval(TimeInterval(max(options.days, 1) * 3 + 3) * 86_400)
        let events = try source.events(from: start, to: horizon).filter { !hidden.contains($0.calendarID) }
        let days = Availability.freeSlots(events: events, from: now(), options: options, calendar: calendar)
        return Availability.formatted(days, calendar: calendar)
    }

    /// The first free stretch of `duration` in working hours over the next working days, for
    /// Block Time. Nil when there's none; Block Time never offers a time that's taken.
    func nextFreeSlot(lasting duration: TimeInterval, options: Availability.Options, hidden: Set<String> = []) -> DateInterval? {
        let now = now()
        return Availability.firstSlot(
            lasting: duration, events: upcoming(after: now, hidden: hidden), from: now, options: options, calendar: calendar)
    }

    /// Whether `interval` is still free in the cache, for checking a proposed slot again.
    func isFree(_ interval: DateInterval, hidden: Set<String> = []) -> Bool {
        Availability.isFree(interval, events: events.filter { !hidden.contains($0.calendarID) })
    }

    /// Whether Block Time may still write `interval`: it hasn't started, it's inside working
    /// hours on a working day, and nothing in the cache takes any of it.
    func isBookable(_ interval: DateInterval, options: Availability.Options, hidden: Set<String> = []) -> Bool {
        Availability.isWithinWorkingHours(interval, options: options, calendar: calendar) && interval.start >= now()
            && isFree(interval, hidden: hidden)
    }

    // MARK: Text

    /// “9:00 – 9:30 AM”, or “All day”.
    func timeRange(of event: CalendarEvent, locale: Locale = .current) -> String {
        guard !event.isAllDay else { return "All day" }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: event.start, to: max(event.start, event.end))
    }

    /// “in 5 min”, “now”, “5 min ago”, relative to the start.
    static func relativeStart(of event: CalendarEvent, now: Date) -> String {
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if event.isOngoing(at: now) {
            let elapsed = Int(now.timeIntervalSince(event.start) / 60)
            return elapsed < 1 ? "Now" : "Started \(elapsed) min ago"
        }
        if minutes <= 0 { return "Now" }
        if minutes < 60 { return "In \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "In \(hours) h" : "In \(hours) h \(rest) min"
    }

    /// Plain text for Copy Event Details.
    func details(of event: CalendarEvent) -> String {
        var lines = [event.title, timeRange(of: event)]
        if let location = event.location, !location.isEmpty { lines.append(location) }
        if let link = event.meetingLink { lines.append("\(link.provider.title): \(link.url.absoluteString)") }
        let guests = event.attendees.map(\.displayName)
        if !guests.isEmpty { lines.append("Guests: " + guests.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
