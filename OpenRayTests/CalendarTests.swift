import AppKit
import Foundation
import Testing

@testable import OpenRay

// MARK: - Fakes

@MainActor
final class FakeCalendarSource: CalendarEventSource {
    var access: CalendarAccess
    var grantOnRequest: CalendarAccess = .fullAccess
    var stored: [CalendarEvent] = []
    var calendarList: [CalendarInfo] = []
    var onChange: (@MainActor () -> Void)?
    private(set) var requestCount = 0
    private(set) var readCount = 0
    private(set) var created: [CalendarEvent] = []

    init(access: CalendarAccess = .notDetermined) {
        self.access = access
    }

    func requestAccess() async -> CalendarAccess {
        requestCount += 1
        access = grantOnRequest
        return access
    }

    func calendars() -> [CalendarInfo] { calendarList }

    func events(from start: Date, to end: Date) throws -> [CalendarEvent] {
        guard access.canRead else { throw CalendarServiceError.noAccess }
        readCount += 1
        return stored.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
    }

    func createEvent(title: String, start: Date, end: Date) throws -> CalendarEvent {
        let event = CalendarEvent(title: title, start: start, end: end, calendarID: "work")
        created.append(event)
        stored.append(event)
        return event
    }
}

@MainActor
final class FakeURLOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) throws { opened.append(url) }
}

enum CalendarFixture {
    /// Gregorian in UTC, weeks from Monday, so dates and weekdays are fixed.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    /// Thursday, November 26, 2026 at the given time, UTC.
    static func date(day: Int = 26, month: Int = 11, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func event(
        _ title: String, day: Int = 26, from start: (Int, Int), to end: (Int, Int), location: String? = nil, notes: String? = nil,
        url: URL? = nil, attendees: [CalendarAttendee] = [], calendarID: String = "work",
        availability: EventAvailability = .busy
    ) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "\(title)-id", title: title, start: date(day: day, start.0, start.1), end: date(day: day, end.0, end.1),
            location: location, notes: notes, url: url, calendarID: calendarID, calendarTitle: "Work", attendees: attendees,
            availability: availability)
    }
}

final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

// MARK: - Links, availability, preferences

struct MeetingLinkTests {
    @Test func detectsZoomMeetTeamsAndWebex() {
        #expect(MeetingLink.detect(in: "Room 4 / https://us02web.zoom.us/j/8812345678?pwd=abc")?.provider == .zoom)
        #expect(MeetingLink.detect(in: "zoommtg://zoom.us/join?confno=123")?.provider == .zoom)
        #expect(MeetingLink.detect(in: "Join: https://meet.google.com/abc-defg-hij.")?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZDk%40thread.v2/0?context=%7b%22Tid%22%7d"
        #expect(MeetingLink.detect(in: "Microsoft Teams meeting\n<\(teams)>")?.url.absoluteString == teams)
        #expect(MeetingLink.detect(in: "https://acme.webex.com/meet/jdoe")?.provider == .webex)
        #expect(MeetingLink.detect(in: "https://acme.webex.com/acme/j.php?MTID=m123")?.provider == .webex)
        // Work and school short links keep their passcode; government clouds and personal links count.
        let short = "https://teams.microsoft.com/meet/2345678901234?p=AbCdEfGhIjKlMn"
        #expect(MeetingLink.detect(in: "Join: \(short)")?.url.absoluteString == short)
        #expect(MeetingLink.detect(in: short)?.provider == .teams)
        let gov = "https://gov.teams.microsoft.us/l/meetup-join/19%3ameeting_X%40thread.v2/0?context=%7b%7d"
        #expect(MeetingLink.detect(in: gov)?.url.absoluteString == gov)
        #expect(MeetingLink.detect(in: "https://teams.live.com/meet/9387653?p=Q1w2E3")?.url.query == "p=Q1w2E3")
        #expect(MeetingLink.detect(in: "https://teams.microsoft.com/v2/") == nil)
        #expect(MeetingLink.detect(in: "See https://example.com/agenda") == nil)
        #expect(MeetingLink.detect(in: nil) == nil)
    }

    @Test func theURLFieldWinsThenLocationThenNotesAndTheEarliestLinkInAText() {
        let zoom = URL(string: "https://zoom.us/j/1")!
        #expect(
            MeetingLink.detect(url: zoom, location: "https://meet.google.com/aaa-bbbb-ccc", notes: nil)?.provider == .zoom)
        #expect(
            MeetingLink.detect(url: URL(string: "https://example.com"), location: "https://meet.google.com/aaa-bbbb-ccc", notes: nil)?
                .provider == .googleMeet)
        #expect(MeetingLink.detect(url: nil, location: "Office", notes: "dial in https://acme.webex.com/meet/x")?.provider == .webex)
        #expect(
            MeetingLink.detect(in: "backup https://zoom.us/j/9 primary https://meet.google.com/aaa-bbbb-ccc")?.provider == .zoom)
    }
}

struct AvailabilityTests {
    private let calendar = CalendarFixture.calendar
    private let events = [
        CalendarFixture.event("Sync", from: (10, 30), to: (11, 0)),
        CalendarFixture.event("Lunch", from: (13, 0), to: (14, 0)),
        CalendarFixture.event("Optional", from: (15, 0), to: (16, 0), availability: .free),
        CalendarEvent(
            title: "Holiday", start: CalendarFixture.date(day: 27, 0), end: CalendarFixture.date(day: 28, 0), isAllDay: true),
    ]

    private func hhmm(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    @Test func freeSlotsSkipBusyEventsShortGapsAndWeekends() {
        var options = Availability.Options()
        options.days = 3
        let days = Availability.freeSlots(
            events: events, from: CalendarFixture.date(10, 7), options: options, calendar: calendar)
        // Thursday, Friday, then Monday: the weekend is skipped.
        #expect(days.map { calendar.component(.day, from: $0.day) } == [26, 27, 30])
        // 10:15–10:30 is only 15 minutes; the free “Optional” event and the all-day holiday don't count.
        #expect(days[0].slots.map { "\(hhmm($0.start))-\(hhmm($0.end))" } == ["11:00-13:00", "14:00-17:00"])
        #expect(days[1].slots.map { "\(hhmm($0.start))-\(hhmm($0.end))" } == ["09:00-17:00"])
        options.skipsWeekends = false
        let withWeekend = Availability.freeSlots(events: events, from: CalendarFixture.date(10, 7), options: options, calendar: calendar)
        #expect(withWeekend.map { calendar.component(.day, from: $0.day) } == [26, 27, 28])
    }

    @Test func availabilityFormatsOneLinePerDay() {
        var options = Availability.Options()
        options.days = 2
        let days = Availability.freeSlots(events: events, from: CalendarFixture.date(16, 45), options: options, calendar: calendar)
        let text = Availability.format(
            days, dayLabel: { "Day \(calendar.component(.day, from: $0))" },
            range: { "\(hhmm($0.start))–\(hhmm($0.end))" }, timeZoneName: "UTC")
        #expect(text == "My availability (UTC):\nDay 26: no free time\nDay 27: 09:00–17:00")
        // The locale-aware version names each day and the time zone.
        let formatted = Availability.formatted(days, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(formatted.hasPrefix("My availability ("))
        #expect(formatted.contains("Thu, Nov 26: no free time"))
        #expect(formatted.contains("Fri, Nov 27: 9:00"))
    }

    @Test func onlyEventsThatTakeTheirTimeCountAsBusy() {
        let day = CalendarFixture.date(day: 27, 0)
        let nextDay = CalendarFixture.date(day: 28, 0)
        let allDayBusy = CalendarEvent(title: "Offsite", start: day, end: nextDay, isAllDay: true, availability: .busy)
        let allDayUnmarked = CalendarEvent(title: "Holiday", start: day, end: nextDay, isAllDay: true)
        let timedFree = CalendarFixture.event("Optional", day: 27, from: (9, 0), to: (10, 0), availability: .free)
        let timedTentative = CalendarFixture.event("Maybe", day: 27, from: (10, 0), to: (11, 0), availability: .tentative)
        let timedUnmarked = CalendarFixture.event("Unmarked", day: 27, from: (11, 0), to: (12, 0), availability: .unspecified)
        #expect(allDayBusy.blocksTime && !allDayUnmarked.blocksTime && !timedFree.blocksTime)
        #expect(timedTentative.blocksTime && timedUnmarked.blocksTime)
        var options = Availability.Options()
        options.days = 2
        let blocked = Availability.freeSlots(events: [allDayBusy], from: CalendarFixture.date(10, 7), options: options, calendar: calendar)
        #expect(blocked[1].slots.isEmpty)
        let open = Availability.freeSlots(
            events: [allDayUnmarked, timedFree, timedTentative, timedUnmarked], from: CalendarFixture.date(10, 7), options: options,
            calendar: calendar)
        #expect(open[1].slots.map { "\(hhmm($0.start))-\(hhmm($0.end))" } == ["09:00-10:00", "12:00-17:00"])
    }

    @Test func workingHoursKeepTheirWallClockTimeAcrossDaylightSaving() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // Clocks jump from 2:00 to 3:00 on Sunday, March 8, 2026.
        let sunday = try #require(newYork.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let start = try #require(Availability.wallClock(9 * 60, on: sunday, calendar: newYork))
        let end = try #require(Availability.wallClock(17 * 60, on: sunday, calendar: newYork))
        #expect(newYork.component(.hour, from: start) == 9)
        #expect(newYork.component(.hour, from: end) == 17)
        #expect(Availability.wallClock(1_440, on: sunday, calendar: newYork) == newYork.date(byAdding: .day, value: 1, to: sunday))
    }

    @Test func slotsStartOnTheNextQuarterHour() {
        #expect(hhmm(Availability.roundedUp(CalendarFixture.date(10, 7, second: 30), toMinutes: 15, calendar: calendar)) == "10:15")
        #expect(hhmm(Availability.roundedUp(CalendarFixture.date(10, 15), toMinutes: 15, calendar: calendar)) == "10:15")
        #expect(hhmm(Availability.roundedUp(CalendarFixture.date(10, 15, second: 1), toMinutes: 15, calendar: calendar)) == "10:30")
        let slot = Availability.firstSlot(
            lasting: 7_200, events: events, from: CalendarFixture.date(10, 7), options: .init(), calendar: calendar)
        #expect(slot.map { "\(hhmm($0.start))-\(hhmm($0.end))" } == "11:00-13:00")
    }

    @Test func preferencesRoundTripAndIgnoreBadValues() {
        var preferences = CalendarPreferences()
        preferences.rootLeadMinutes = 5
        preferences.hiddenCalendarIDs = ["b", "a"]
        preferences.availability.days = 5
        preferences.availability.skipsWeekends = false
        #expect(CalendarPreferences(preferences.values) == preferences)
        let bad = CalendarPreferences(["rootLead": "-3", "availabilityDays": "99", "dayStart": "x"])
        #expect(bad == CalendarPreferences())
    }
}

// MARK: - Service

@MainActor
struct CalendarServiceTests {
    private func makeService(
        access: CalendarAccess = .fullAccess, events: [CalendarEvent] = [], now: Date = CalendarFixture.date(10, 7)
    ) -> (CalendarService, FakeCalendarSource, FakeURLOpener, MutableClock) {
        let source = FakeCalendarSource(access: access)
        source.stored = events
        let opener = FakeURLOpener()
        let clock = MutableClock(now)
        let service = CalendarService(source: source, opener: opener, now: { clock.now }, calendar: CalendarFixture.calendar)
        return (service, source, opener, clock)
    }

    @Test func creatingTheServiceNeverAsksForAccessOrReadsEvents() {
        let (service, source, _, _) = makeService(access: .notDetermined)
        #expect(service.access == .notDetermined)
        #expect(source.requestCount == 0 && source.readCount == 0)
        service.refresh()
        #expect(source.readCount == 0)
        #expect(service.events.isEmpty)
    }

    @Test func accessIsRequestedOnlyOnce() async {
        let (service, source, _, _) = makeService(access: .notDetermined, events: [CalendarFixture.event("A", from: (11, 0), to: (12, 0))])
        await service.requestAccessIfNeeded()
        await service.requestAccessIfNeeded()
        #expect(source.requestCount == 1)
        #expect(service.access == .fullAccess)
        #expect(service.events.map(\.title) == ["A"])
    }

    @Test func theNextEventShowsInRootSearchAroundItsStart() {
        let standup = CalendarFixture.event("Standup", from: (10, 20), to: (10, 35), location: "https://zoom.us/j/42")
        let (service, _, _, clock) = makeService(events: [standup])
        service.refresh()
        #expect(service.nextEventForRoot(leadMinutes: 10) == nil)
        clock.now = CalendarFixture.date(10, 10)
        #expect(service.nextEventForRoot(leadMinutes: 10)?.title == "Standup")
        clock.now = CalendarFixture.date(10, 30)
        #expect(service.nextEventForRoot(leadMinutes: 10)?.title == "Standup")
        clock.now = CalendarFixture.date(10, 31)
        #expect(service.nextEventForRoot(leadMinutes: 10) == nil)
        // Hidden calendars are left out.
        clock.now = CalendarFixture.date(10, 15)
        #expect(service.nextEventForRoot(leadMinutes: 10, hidden: ["work"]) == nil)
    }

    @Test func actionsOpenLinksThroughTheOpener() throws {
        let me = CalendarAttendee(name: "Me", email: "me@x.com", status: .pending, isCurrentUser: true)
        let guests = [me, CalendarAttendee(name: "Ana", email: "ana@x.com"), CalendarAttendee(name: "Bo", email: "bo@y.com")]
        let event = CalendarFixture.event(
            "Plan & Review", from: (11, 0), to: (12, 0), notes: "https://meet.google.com/abc-defg-hij", attendees: guests)
        let (service, _, opener, _) = makeService(events: [event])
        try service.join(event)
        try service.openInCalendar(event)
        try service.emailAttendees(of: event)
        #expect(opener.opened.map(\.absoluteString) == [
            "https://meet.google.com/abc-defg-hij", "ical://ekevent/Plan%20&%20Review-id?method=show&options=more",
            "mailto:ana@x.com,bo@y.com?subject=Plan%20%26%20Review",
        ])
        #expect(event.myStatus == .pending)
        #expect(throws: CalendarServiceError.self) { try service.join(CalendarFixture.event("No link", from: (1, 0), to: (2, 0))) }
    }

    @Test func relativeStartsReadNaturally() {
        let event = CalendarFixture.event("E", from: (11, 0), to: (12, 0))
        #expect(CalendarService.relativeStart(of: event, now: CalendarFixture.date(10, 55)) == "In 5 min")
        #expect(CalendarService.relativeStart(of: event, now: CalendarFixture.date(9, 30)) == "In 1 h 30 min")
        #expect(CalendarService.relativeStart(of: event, now: CalendarFixture.date(11, 0)) == "Now")
        #expect(CalendarService.relativeStart(of: event, now: CalendarFixture.date(11, 12)) == "Started 12 min ago")
    }

    @Test func theLiveSourceAndOpenerAreInertInTests() async throws {
        let source = EventKitCalendarSource(guardrail: SideEffectGuard(mode: .testHost))
        #expect(source.access == .unavailable)
        #expect(await source.requestAccess() == .unavailable)
        #expect(throws: (any Error).self) { try source.events(from: .now, to: .now.addingTimeInterval(60)) }
        #expect(throws: (any Error).self) { try source.createEvent(title: "x", start: .now, end: .now) }
        #expect(source.calendars().isEmpty)
        let opener = WorkspaceURLOpener(guardrail: SideEffectGuard(mode: .verification))
        #expect(throws: SideEffectGuard.Blocked.self) { try opener.open(URL(string: "https://zoom.us/j/1")!) }
    }
}

// MARK: - Provider

@MainActor
struct CalendarProviderTests {
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func make(access: CalendarAccess = .fullAccess, events: [CalendarEvent] = [], now: Date = CalendarFixture.date(10, 7))
        -> (LauncherModel, CalendarService, FakeCalendarSource, FakeURLOpener)
    {
        let source = FakeCalendarSource(access: access)
        source.stored = events
        let opener = FakeURLOpener()
        let service = CalendarService(source: source, opener: opener, now: { now }, calendar: CalendarFixture.calendar)
        let model = LauncherModel(
            store: LibraryStore(fileURL: nil), ai: AIChatModel(engine: TestAIEngine()), pasteboard: NSPasteboard.withUniqueName(),
            registry: CommandRegistry(providers: [CalendarCommandProvider(service: service)]))
        return (model, service, source, opener)
    }

    @Test func myScheduleAsksForAccessTheFirstTimeItOpens() async throws {
        let (model, service, source, opener) = make(access: .notDetermined, events: [CalendarFixture.event("A", from: (11, 0), to: (12, 0))])
        #expect(source.requestCount == 0)
        model.navigate(to: .provided(CalendarCommandProvider.scope))
        #expect(model.results.map(\.id) == ["calendar.access.request"])
        await settle()
        #expect(source.requestCount == 1)
        #expect(service.access == .fullAccess)
        #expect(model.results.map(\.title) == ["A"])

        // Turned off later: a row opens the privacy settings.
        source.access = .denied
        service.updateAccess()
        let row = try #require(model.results.first)
        #expect(row.id == "calendar.access.settings")
        model.perform(row)
        #expect(opener.opened == [CalendarCommandProvider.privacySettingsURL])
    }

    @Test func eventsAreGroupedByDayWithANowLine() throws {
        let events = [
            CalendarFixture.event("Earlier", from: (8, 0), to: (9, 0)),
            CalendarFixture.event("Standup", from: (10, 30), to: (10, 45), location: "https://zoom.us/j/42"),
            CalendarFixture.event("Review", day: 27, from: (9, 0), to: (10, 0)),
            CalendarFixture.event("Planning", day: 30, from: (9, 0), to: (10, 0)),
            CalendarFixture.allDay("Offsite", month: 12, day: 14),
        ]
        let (model, service, _, _) = make(events: events)
        service.refresh()
        model.navigate(to: .provided(CalendarCommandProvider.scope))
        let groups = model.groups
        #expect(groups.map(\.title) == ["Today", "Tomorrow", "Next Week", "December 2026"])
        #expect(groups.allSatisfy { $0.style == .grid && $0.columns == 1 && $0.tile != nil })
        #expect(groups[0].items.map(\.title) == ["Earlier", "Standup"])
        // The now line goes above the first event today that hasn't ended.
        let refs = groups[0].items.compactMap { item -> String? in
            if case .provided(let ref) = item.action { return ref.payload }
            return nil
        }
        #expect(refs == ["scope", "now"])
        // ↩ opens in Calendar; ⌘↩ joins when there's a link.
        let standup = groups[0].items[1]
        #expect(model.primaryTitle(for: standup) == "Open in Calendar")
        #expect(model.secondaryTitle(for: standup) == "Join Meeting")
        #expect(model.secondaryTitle(for: groups[0].items[0]) == nil)
        // Search filters by title, location and guests.
        model.query = "review"
        #expect(model.results.map(\.title) == ["Review"])
    }

    @Test func sectionsFollowTheWeekAndMonth() {
        let calendar = CalendarFixture.calendar
        let now = CalendarFixture.date(10, 0)
        func title(_ day: Int, month: Int = 11) -> String {
            CalendarCommandProvider.section(for: CalendarFixture.date(day: day, month: month, 9), now: now, calendar: calendar).title
        }
        #expect(title(26) == "Today")
        #expect(title(27) == "Tomorrow")
        #expect(title(29) == "Sunday")
        #expect(title(30) == "Next Week")
        #expect(title(6, month: 12) == "Next Week")
        #expect(title(14, month: 12) == "December 2026")
    }

    @Test func theNextMeetingJoinsFromRootSearch() throws {
        let standup = CalendarFixture.event("Standup", from: (10, 15), to: (10, 30), location: "https://zoom.us/j/42")
        let (model, service, _, opener) = make(events: [standup])
        service.refresh()
        model.query = "standup"
        let row = try #require(model.results.first { $0.id.hasPrefix("calendar.event.") })
        #expect(row.subtitle.hasPrefix("In 8 min"))
        #expect(model.primaryTitle(for: row) == "Join Meeting")
        model.perform(row)
        #expect(opener.opened.map(\.absoluteString) == ["https://zoom.us/j/42"])
        // Not without a query, and not outside the window.
        model.query = "planning"
        #expect(!model.results.contains { $0.id.hasPrefix("calendar.event.") })
        model.files.stop()
    }

    @Test func blockTimeAsksThenAddsTheEvent() throws {
        let (model, service, source, _) = make(events: [CalendarFixture.event("Sync", from: (10, 30), to: (11, 0))])
        service.refresh()
        let command = try #require(model.commandItems.first { $0.id == CalendarCommandProvider.blockTimeID })
        model.perform(command)
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.question.hasPrefix("Block 1 h today"))
        #expect(source.created.isEmpty)
        model.confirm(confirmation)
        #expect(source.created.map(\.title) == ["Focus Time"])
        // The first free hour after 10:07: 11:00–12:00, since Sync holds 10:30.
        #expect(source.created.first?.start == CalendarFixture.date(11, 0))
        #expect(source.created.first?.end == CalendarFixture.date(12, 0))
        #expect(model.feedback?.text.hasPrefix("Blocked today") == true)
    }

    @Test func blockTimeSaysSoWhenNothingIsFree() throws {
        // Every working hour of the next week is taken.
        let busy = (0..<14).map { offset -> CalendarEvent in
            let day = CalendarFixture.calendar.date(byAdding: .day, value: offset, to: CalendarFixture.date(0))!
            return CalendarEvent(
                title: "Busy \(offset)", start: day, end: day.addingTimeInterval(86_400), isAllDay: true, availability: .busy)
        }
        let (model, service, source, _) = make(events: busy)
        service.refresh()
        let command = try #require(model.commandItems.first { $0.id == CalendarCommandProvider.blockTimeID })
        model.perform(command)
        #expect(model.confirmation == nil)
        #expect(model.feedback?.text.hasPrefix("There's no free 1 h") == true)
        #expect(source.created.isEmpty)
    }

    @Test func blockTimeChecksTheSlotAgainWhenConfirmed() throws {
        let (model, service, source, _) = make(events: [CalendarFixture.event("Sync", from: (10, 30), to: (11, 0))])
        service.refresh()
        let command = try #require(model.commandItems.first { $0.id == CalendarCommandProvider.blockTimeID })
        model.perform(command)
        let first = try #require(model.confirmation)
        // While the question is up, someone books 11:00.
        source.stored.append(CalendarFixture.event("Booked", from: (11, 0), to: (11, 30)))
        model.confirm(first)
        #expect(source.created.isEmpty)
        let second = try #require(model.confirmation)
        #expect(second.question.hasPrefix("That time was just taken. Block 1 h today"))
        model.confirm(second)
        #expect(source.created.first?.start == CalendarFixture.date(11, 30))
        #expect(source.created.first?.end == CalendarFixture.date(12, 30))
    }

    @Test func copyAvailabilityCopiesAndSaysSo() throws {
        let (model, service, _, _) = make()
        service.refresh()
        var command = try #require(model.commandItems.first { $0.id == CalendarCommandProvider.availabilityID })
        if case .provided(var ref) = command.action {
            ref.arguments = ["days": "1"]
            command.action = .provided(ref)
        }
        model.perform(command)
        #expect(model.feedback?.text == "Copied your availability for the next 1 working day")
    }

    @Test func commandsWithoutAccessSayWhy() throws {
        let (model, _, _, _) = make(access: .denied)
        let block = try #require(model.commandItems.first { $0.id == CalendarCommandProvider.blockTimeID })
        #expect(block.subtitle.contains("System Settings"))
        model.perform(block)
        #expect(model.confirmation == nil)
        #expect(model.feedback?.style == .warning)
        // Calendar commands can take aliases and hotkeys.
        CuratedCommand.$registrations.withValue([CalendarCommandProvider.registration]) {
            #expect(CuratedCommand.supports(CalendarCommandProvider.joinNextID))
        }
    }

    @Test func verificationModeExplainsTheEmptySchedule() {
        let (model, _, _, _) = make(access: .unavailable)
        model.navigate(to: .provided(CalendarCommandProvider.scope))
        #expect(model.results.isEmpty)
        #expect(model.providedEmptyState(for: CalendarCommandProvider.scope).title == "Calendars aren't read here")
    }
}

extension CalendarFixture {
    /// An all-day event.
    static func allDay(_ title: String, month: Int, day: Int) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "\(title)-id", title: title, start: date(day: day, month: month, 0),
            end: date(day: day + 1, month: month, 0), isAllDay: true, calendarID: "work", calendarTitle: "Work")
    }
}
