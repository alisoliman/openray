import Foundation
import Testing

@testable import OpenRay

/// A fixed clock, calendar and locale: Wednesday 25 November 2026, 14:30 in London
/// (GMT), US English formats, Saturday–Sunday weekends.
enum CalculatorClock {
    static let timeZone = TimeZone(identifier: "Europe/London")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static let now = date(2026, 11, 25, 14, 30)

    static func context(
        now: Date = now, locale: Locale = Locale(identifier: "en_US_POSIX"), rates: CurrencyRateTable? = nil,
        pixelsPerEm: Double = 16
    ) -> CalculatorContext {
        CalculatorContext(now: now, calendar: calendar, locale: locale, currencyRates: rates, pixelsPerEm: pixelsPerEm)
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in zone: TimeZone? = nil)
        -> Date
    {
        var calendar = calendar
        if let zone { calendar.timeZone = zone }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func evaluate(_ input: String, context: CalculatorContext = context()) -> Calculation? {
        Calculator.evaluate(input, context: context)
    }
}

struct CalculatorDatesTests {
    private typealias Clock = CalculatorClock

    @Test(arguments: [
        ("days until 31 Mar", "126 days", "126"),
        ("days until 31 march 2027", "126 days", "126"),
        ("how many days until christmas", "30 days", "30"),
        ("days till new year", "37 days", "37"),
        ("days since 1 jan", "328 days", "328"),
        ("days since march", "269 days", "269"),
        ("days until december", "6 days", "6"),
        ("weeks until 30 dec", "5 weeks", "5"),
        ("days between 1 jan and 31 mar", "89 days", "89"),
        ("days from 1 jan to 31 mar", "89 days", "89"),
        ("days left in this month", "6 days", "6"),
        ("days left in the year", "37 days", "37"),
        ("days until friday", "2 days", "2"),
        ("days since monday", "2 days", "2"),
    ])
    func countsDays(input: String, result: String, value: String) throws {
        let calculation = try #require(Clock.evaluate(input))
        #expect(calculation.result == result)
        #expect(calculation.value == value)
        #expect(calculation.kind == .duration)
    }

    @Test func countNamesTheDateAndBreakdown() throws {
        let calculation = try #require(Clock.evaluate("days until 31 Mar"))
        #expect(calculation.date == Clock.date(2027, 3, 31))
        #expect(calculation.detail.contains("4 months, 6 days"))
        #expect(calculation.detail.hasSuffix("Return to copy"))
    }

    @Test(arguments: [
        // Wed 25 Nov to Fri 4 Dec: Wed–Fri, then Mon–Thu.
        ("workdays until 4 dec", "7 workdays"),
        ("business days until 4 dec", "7 workdays"),
        ("workdays left in this month", "4 workdays"),
        ("workdays between 1 dec and 1 jan", "23 workdays"),
    ])
    func countsWorkdaysWithoutWeekends(input: String, result: String) throws {
        #expect(Clock.evaluate(input)?.result == result)
    }

    @Test func workdayHelpersSkipWeekends() {
        let calendar = Clock.calendar
        let friday = Clock.date(2026, 11, 27)
        let monday = Clock.date(2026, 11, 30)
        #expect(DateMath.workdays(from: friday, to: monday, calendar: calendar) == 1)
        #expect(DateMath.workdays(from: monday, to: friday, calendar: calendar) == -1)
        #expect(DateMath.workdays(from: Clock.date(2026, 1, 1), to: Clock.date(2027, 1, 1), calendar: calendar) == 261)
        #expect(DateMath.adding(workdays: 1, to: friday, calendar: calendar) == monday)
        #expect(DateMath.adding(workdays: -1, to: monday, calendar: calendar) == friday)
    }

    @Test(arguments: [
        ("monday in 3 weeks", 2026, 12, 14),
        ("friday in 2 weeks", 2026, 12, 11),
        ("3 weeks from today", 2026, 12, 16),
        ("3 weeks from now", 2026, 12, 16),
        ("2 weeks ago", 2026, 11, 11),
        ("a month ago", 2026, 10, 25),
        ("in 3 days", 2026, 11, 28),
        ("in 2 weeks and 3 days", 2026, 12, 12),
        ("today + 3 days", 2026, 11, 28),
        ("today plus 1 year", 2027, 11, 25),
        ("31 mar - 2 weeks", 2026, 3, 17),
        ("10 days after 31 mar", 2026, 4, 10),
        ("2 days before christmas", 2026, 12, 23),
        ("10 workdays from today", 2026, 12, 9),
        ("next friday", 2026, 11, 27),
        ("this friday", 2026, 11, 27),
        ("last monday", 2026, 11, 23),
        ("next week", 2026, 12, 2),
        ("tomorrow", 2026, 11, 26),
        ("yesterday", 2026, 11, 24),
        ("today", 2026, 11, 25),
        ("31 mar 2027", 2027, 3, 31),
        ("march 31st 2027", 2027, 3, 31),
        ("the 4th of july 2027", 2027, 7, 4),
        ("2027-02-28", 2027, 2, 28),
        ("easter 2027", 2027, 3, 28),
        ("christmas 2027", 2027, 12, 25),
        ("end of month", 2026, 11, 30),
        ("end of next month", 2026, 12, 31),
    ])
    func resolvesDates(input: String, year: Int, month: Int, day: Int) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.kind == .date)
        #expect(calculation.date == Clock.date(year, month, day))
    }

    @Test func datesUseTheContextLocale() throws {
        let calculation = try #require(Clock.evaluate("monday in 3 weeks"))
        #expect(calculation.result == "Monday, December 14, 2026")
        #expect(calculation.detail == "In 19 days · Return to copy")
        #expect(calculation.value == calculation.result)
    }

    @Test func sameTimeTermsKeepTheClockTime() throws {
        let later = try #require(Clock.evaluate("in 4 hours"))
        #expect(later.date == Clock.now.addingTimeInterval(4 * 3_600))
        let time = try #require(Clock.evaluate("time in 4 hours"))
        #expect(time.kind == .time)
        #expect(time.result == "6:30 PM")
        let now = try #require(Clock.evaluate("now"))
        #expect(now.date == Clock.now)
        let bare = try #require(Clock.evaluate("time"))
        #expect(bare.result == "2:30 PM")
        let dated = try #require(Clock.evaluate("tomorrow at 5pm"))
        #expect(dated.date == Clock.date(2026, 11, 26, 17))
    }

    @Test(arguments: [
        ("31 mar - 1 jan", "89 days"),
        ("from 1 jan to 31 mar", "89 days"),
        ("between 1 jan and 31 mar", "89 days"),
        ("1 dec to 1 jan", "31 days"),
        ("10pm to 2am", "4 hours"),
        ("9:15 to 17:45", "8 hours, 30 minutes"),
        ("from 1700000000 to 1700003600", "1 hour"),
    ])
    func differencesBetweenDates(input: String, result: String) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.result == result)
        #expect(calculation.kind == .duration)
    }

    @Test func weekNumbersAreISO() throws {
        let current = try #require(Clock.evaluate("week number"))
        #expect(current.result == "Week 48")
        #expect(current.value == "48")
        #expect(current.date == Clock.date(2026, 11, 23))
        #expect(Clock.evaluate("what week is it")?.value == "48")
        #expect(Clock.evaluate("week number of 1 jan 2027")?.value == "53")
        let week = try #require(Clock.evaluate("week 12"))
        #expect(week.date == Clock.date(2026, 3, 16))
        #expect(week.result.contains("Mar 16, 2026"))
        #expect(Clock.evaluate("week 1 2027")?.date == Clock.date(2027, 1, 4))
        #expect(Clock.evaluate("week 44 2026")?.date == Clock.date(2026, 10, 26))
        #expect(Clock.evaluate("week 54") == nil)
    }

    @Test func unixTimeConvertsBothWays() throws {
        let now = try #require(Clock.evaluate("unix time"))
        #expect(now.result == "\(Int(Clock.now.timeIntervalSince1970))")
        #expect(Clock.evaluate("timestamp")?.result == now.result)

        let seconds = try #require(Clock.evaluate("1700000000 unix"))
        #expect(seconds.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(seconds.detail.hasPrefix("2023-11-14T22:13:20Z"))
        #expect(Clock.evaluate("unix 1700000000")?.date == seconds.date)
        #expect(Clock.evaluate("1700000000000 to date")?.date == seconds.date)

        let back = try #require(Clock.evaluate("31 mar 2027 to unix"))
        #expect(back.result == "\(Int(Clock.date(2027, 3, 31).timeIntervalSince1970))")
        #expect(Clock.evaluate("unix time of 1 jan 2026")?.result == "1767225600")
    }

    @Test func isoTimestampsKeepTheirOffset() throws {
        let zulu = try #require(Clock.evaluate("2024-03-15T14:30:00Z"))
        #expect(zulu.date == Date(timeIntervalSince1970: 1_710_513_000))
        #expect(Clock.evaluate("2024-03-15T15:30:00+01:00")?.date == zulu.date)
    }

    @Test func impossibleDatesAreIssues() {
        #expect(Calculator.issue(for: "days until 31 feb", context: Clock.context()) == .invalidDate)
        #expect(Calculator.issue(for: "30 february 2027", context: Clock.context()) == .invalidDate)
        // February 29 resolves to the next leap year.
        #expect(Clock.evaluate("days until 29 feb")?.date == Clock.date(2028, 2, 29))
    }

    @Test(arguments: [
        "christmas", "friday", "march", "2 days to go", "5 minutes to midnight", "notes from monday",
        "week", "days", "next", "the day", "1 week in days",
    ])
    func proseAndUnitsAreNotDates(_ input: String) {
        let calculation = Clock.evaluate(input)
        #expect(calculation == nil || calculation?.kind == .conversion)
    }

    @Test func easterFollowsTheGregorianComputus() {
        #expect(DateMath.easter(year: 2026) == DateComponents(year: 2026, month: 4, day: 5))
        #expect(DateMath.easter(year: 2027) == DateComponents(year: 2027, month: 3, day: 28))
        #expect(DateMath.easter(year: 2038) == DateComponents(year: 2038, month: 4, day: 25))
    }

    @Test(arguments: [
        ("5pm", 17, 0), ("5 pm", 17, 0), ("5:30pm", 17, 30), ("12am", 0, 0), ("12pm", 12, 0), ("17:45", 17, 45),
        ("noon", 12, 0), ("midnight", 0, 0), ("9:05 a.m.", 9, 5),
    ])
    func timesOfDay(input: String, hour: Int, minute: Int) throws {
        let tokens = DateMath.tokenize(input)
        let parsed = try #require(TimeOfDay.parse(tokens, at: 0))
        #expect(parsed.time == TimeOfDay(hour: hour, minute: minute))
        #expect(parsed.length == tokens.count)
    }

    @Test(arguments: ["5", "25:00", "13pm", "5:75"])
    func bareNumbersAreNotTimes(_ input: String) {
        #expect(TimeOfDay.parse(DateMath.tokenize(input), at: 0) == nil)
    }
}

struct CalculatorTimeZoneTests {
    private typealias Clock = CalculatorClock

    @Test(arguments: [
        ("5pm ldn in sf", "9:00 AM"),
        ("5pm london in san francisco", "9:00 AM"),
        ("10am PST to CET", "7:00 PM"),
        ("5pm new york in sf", "2:00 PM"),
        ("17:00 utc to tokyo", "2:00 AM"),
        ("9am jfk in lhr", "2:00 PM"),
        ("17:00 utc+5:30 in utc", "11:30 AM"),
        ("noon sydney in berlin", "2:00 AM"),
        ("5pm in tokyo", "2:00 AM"),
        ("5pm tokyo", "8:00 AM"),
        ("3pm est", "8:00 PM"),
    ])
    func convertsTimesBetweenZones(input: String, result: String) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.result == result)
        #expect(calculation.kind == .time)
    }

    @Test func conversionsLabelBothSides() throws {
        let calculation = try #require(Clock.evaluate("5pm ldn in sf"))
        #expect(calculation.inputLabel == "5:00 PM · London (GMT)")
        #expect(calculation.resultLabel == "San Francisco (PST) · Wednesday, November 25")
        #expect(calculation.detail.contains("8 hours behind London"))
        #expect(calculation.swapQuery == "5pm sf in ldn")
        #expect(Clock.evaluate("5pm in tokyo")?.resultLabel?.contains("Thursday") == true)
    }

    @Test(arguments: [
        ("time in tokyo", "11:30 PM"),
        ("what time is it in new york", "9:30 AM"),
        ("tokyo time", "11:30 PM"),
        ("time in São Paulo", "11:30 AM"),
        ("time in mumbai", "8:00 PM"),
        ("time in kathmandu", "8:15 PM"),
        ("time in pst", "6:30 AM"),
        ("now in sydney", "1:30 AM"),
        ("time in europe/paris", "3:30 PM"),
    ])
    func currentTimeElsewhere(input: String, result: String) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.result == result)
    }

    @Test func differencesBetweenZones() throws {
        let tokyo = try #require(Clock.evaluate("time diff tokyo"))
        #expect(tokyo.result == "+9 h")
        #expect(tokyo.detail.hasPrefix("Tokyo is 9 hours ahead of local time"))
        #expect(Clock.evaluate("time difference between new york and london")?.result == "-5 h")
        #expect(Clock.evaluate("diff mumbai")?.result == "+5.5 h")
    }

    @Test func daylightSavingFollowsTheDate() throws {
        let summer = Clock.context(now: Clock.date(2026, 7, 1, 12))
        #expect(Calculator.evaluate("5pm ldn in sf", context: summer)?.result == "9:00 AM")
        #expect(Calculator.evaluate("time in new york", context: summer)?.result == "7:00 AM")
    }

    @Test func tableResolvesNamesCodesAndOffsets() {
        #expect(TimeZoneTable.zone(named: "LDN")?.timeZone.identifier == "Europe/London")
        #expect(TimeZoneTable.zone(named: "SFO")?.timeZone.identifier == "America/Los_Angeles")
        #expect(TimeZoneTable.zone(named: "ist")?.timeZone.identifier == "Asia/Kolkata")
        #expect(TimeZoneTable.zone(named: "Zürich")?.timeZone.identifier == "Europe/Zurich")
        #expect(TimeZoneTable.zone(named: "reykjavik")?.timeZone.identifier == "Atlantic/Reykjavik")
        #expect(TimeZoneTable.zone(named: "utc-3")?.timeZone.secondsFromGMT() == -10_800)
        #expect(TimeZoneTable.zone(named: "gmt")?.timeZone.secondsFromGMT() == 0)
        #expect(TimeZoneTable.zone(named: "atlantis") == nil)
        #expect(TimeZoneTable.zone(named: "de") == nil)
    }

    @Test(arguments: ["time in 4 days", "5pm meeting", "time in atlantis", "5 in in cm", "breakfast time"])
    func nonZonesFallThrough(_ input: String) {
        #expect(Clock.evaluate(input)?.kind != .time || input == "time in 4 days")
    }
}
