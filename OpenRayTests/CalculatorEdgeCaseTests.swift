import Foundation
import Testing

@testable import OpenRay

/// Regressions from the Phase A review: inputs that trapped, silently gave wrong
/// answers, or took over root search.
struct CalculatorEdgeCaseTests {
    private typealias Clock = CalculatorClock

    private func issue(_ input: String, context: CalculatorContext = CalculatorClock.context()) -> Calculator.Issue? {
        Calculator.issue(for: input, context: context)
    }

    // MARK: Oversized durations never trap

    @Test(arguments: [
        "in 1e20 days", "in 1e20 workdays", "1e20 workdays from today", "in 20000 workdays", "today + 1e20 months",
        "in 99999 years", "in 1e300 seconds", "10000 workdays and 10000 workdays from today", "1e20 days ago",
        "monday in 1e20 weeks", "in 9000 years and 9000 years",
    ])
    func oversizedDurationsAreOutOfRange(_ input: String) {
        #expect(issue(input) == .resultOutOfRange, "\(input)")
        #expect(Clock.evaluate(input) == nil)
    }

    @Test(arguments: ["1e20 days archive", "in inf days", "in nan days", "1e20 workdays notes", "-9e18 days ago"])
    func oversizedProseNeverTraps(_ input: String) {
        #expect(issue(input) != nil)
    }

    @Test func largeButValidWorkdaysStayFast() throws {
        let calculation = try #require(Clock.evaluate("9999 workdays from today"))
        #expect(calculation.kind == .date)
    }

    @Test func weekJumpsMatchWalkingDayByDay() {
        let calendar = Clock.calendar
        func walked(_ workdays: Int, from start: Date) -> Date {
            var date = start
            var remaining = abs(workdays)
            while remaining > 0 {
                date = calendar.date(byAdding: .day, value: workdays < 0 ? -1 : 1, to: date)!
                if !calendar.isDateInWeekend(date) { remaining -= 1 }
            }
            return date
        }
        for offset in 0..<7 {
            let start = calendar.date(byAdding: .day, value: offset, to: Clock.date(2026, 11, 23))!
            for workdays in [-23, -6, -5, -1, 0, 1, 4, 5, 6, 9, 10, 11, 37] {
                #expect(DateMath.adding(workdays: workdays, to: start, calendar: calendar) == walked(workdays, from: start))
            }
        }
        #expect(DateMath.adding(workdays: DateMath.maximumWorkdays + 1, to: Clock.now, calendar: calendar) == nil)
        #expect(DateMath.adding(workdays: .min, to: Clock.now, calendar: calendar) == nil)
    }

    // MARK: Frequencies

    @Test(arguments: ["1e-323 hz to note", "0.001 hz to note", "1e9 hz to note", "1e308 khz to note"])
    func outOfRangeFrequenciesAreIssues(_ input: String) {
        #expect(issue(input) == .resultOutOfRange)
    }

    @Test func nearestNoteRejectsExtremes() {
        #expect(MusicNote.nearest(to: 1e-323) == nil)
        #expect(MusicNote.nearest(to: .leastNonzeroMagnitude) == nil)
        #expect(MusicNote.nearest(to: 440)?.name == "A4")
    }

    // MARK: ISO dates, offsets and calendars

    @Test(arguments: [
        "2027-02-29", "2027-02-29T12:00:00Z", "2024-03-15T25:00:00Z", "2024-03-15T14:61:00Z",
        "2024-03-15T14:30:00+99:00", "2024-13-01", "days until 2027-02-30",
    ])
    func impossibleISODatesAreIssues(_ input: String) {
        #expect(issue(input) == .invalidDate, "\(input)")
    }

    @Test func isoKeepsFractionalSeconds() throws {
        let calculation = try #require(Clock.evaluate("2024-03-15T14:30:00.250Z"))
        #expect(calculation.date == Date(timeIntervalSince1970: 1_710_513_000.25))
        #expect(Clock.evaluate("2024-03-15T15:30:00+0100")?.date == Date(timeIntervalSince1970: 1_710_513_000))
        #expect(Clock.evaluate("2024-03-15T15:30:00+01")?.date == Date(timeIntervalSince1970: 1_710_513_000))
    }

    @Test func datesStayGregorianUnderAnotherCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = CalculatorClock.timeZone
        buddhist.locale = Locale(identifier: "en_US_POSIX")
        let context = CalculatorContext(
            now: Clock.now, calendar: buddhist, locale: Locale(identifier: "en_US_POSIX"))
        #expect(
            Calculator.evaluate("2024-03-15T14:30:00Z", context: context)?.date
                == Date(timeIntervalSince1970: 1_710_513_000))
        #expect(Calculator.evaluate("31 mar 2027", context: context)?.date == Clock.date(2027, 3, 31))
        #expect(Calculator.evaluate("days until 31 mar", context: context)?.value == "126")
    }

    @Test func impossibleOffsetsAreNotUTC() {
        #expect(TimeZoneTable.zone(named: "utc+99") == nil)
        #expect(TimeZoneTable.zone(named: "gmt-15") == nil)
        #expect(TimeZoneTable.zone(named: "utc+14")?.timeZone.secondsFromGMT() == 50_400)
        #expect(Clock.evaluate("time in utc+99") == nil)
        #expect(Clock.evaluate("5pm utc+99 in tokyo") == nil)
    }

    // MARK: Unix time

    @Test func unixAcceptsSignedAndMarkedValues() throws {
        #expect(Clock.evaluate("unix 0")?.date == Date(timeIntervalSince1970: 0))
        #expect(Clock.evaluate("1970-01-01T00:00:00Z in unix")?.result == "0")
        #expect(Clock.evaluate("unix -86400")?.date == Date(timeIntervalSince1970: -86_400))
        #expect(Clock.evaluate("1969-07-20T20:17:00Z to unix")?.result == "-14182980")
        #expect(Clock.evaluate("0 to date")?.date == Date(timeIntervalSince1970: 0))
        let marked = try #require(Clock.evaluate("1700000000000 ms to date"))
        #expect(marked.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Clock.evaluate("unix ms 1700000000000")?.date == marked.date)
        // Only unmarked input guesses milliseconds from its length.
        #expect(Clock.evaluate("1700000000000 to date")?.date == marked.date)
        #expect(issue("unix 1700000000000") == .resultOutOfRange)
        #expect(Clock.evaluate("unix +86400")?.date == Date(timeIntervalSince1970: 86_400))
        #expect(Clock.evaluate("unix millis +86400000")?.date == Date(timeIntervalSince1970: 86_400))
        #expect(Clock.evaluate("+86400 unix")?.date == Date(timeIntervalSince1970: 86_400))
        #expect(Clock.evaluate("unix 1700000000.5")?.date == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(issue("unix 999999999999999") == .resultOutOfRange)
    }

    @Test func unixCopiesRoundTripAtTheEdgesAndToTheMillisecond() throws {
        let far = try #require(Clock.evaluate("9999-01-01T00:00:00Z to unix"))
        #expect(far.result == "253370764800")
        #expect(Clock.evaluate("unix \(far.value)")?.date == far.date)
        let early = try #require(Clock.evaluate("0001-01-01T00:00:00Z to unix"))
        #expect(Clock.evaluate("unix \(early.value)")?.date == early.date)
        let precise = try #require(Clock.evaluate("2024-03-15T14:30:00.001Z to unix"))
        #expect(precise.value == "1710513000.001")
        let back = try #require(Clock.evaluate("unix \(precise.value)")?.date)
        #expect(DateMath.unixString(back.timeIntervalSince1970) == precise.value)
        let last = try #require(Clock.evaluate("9999-12-31T23:59:59.5Z to unix"))
        #expect(last.value == "253402300799.5")
        #expect(Clock.evaluate("unix \(last.value)")?.date == last.date)
        let micro = try #require(Clock.evaluate("2024-03-15T14:30:00.000250Z to unix"))
        #expect(micro.value == "1710513000.00025")
        let microBack = try #require(Clock.evaluate("unix \(micro.value)")?.date)
        #expect(DateMath.unixString(microBack.timeIntervalSince1970) == micro.value)
        #expect(DateMath.unixString(-0.5) == "-0.5")
        #expect(DateMath.unixString(-86_400) == "-86400")
        #expect(DateMath.unixString(1.25) == "1.25")
    }

    @Test func unixRoundTrips() throws {
        for seconds in [0, 1, -1, 86_400, 1_700_000_000, -2_208_988_800] {
            let date = try #require(Clock.evaluate("unix \(seconds)")?.date)
            let iso = date.formatted(.iso8601)
            #expect(Clock.evaluate("\(iso) to unix")?.result == "\(seconds)", "\(seconds)")
        }
    }

    @Test func timedDifferencesKeepSeconds() throws {
        let short = try #require(Clock.evaluate("from 1700000000 to 1700000030"))
        #expect(short.result == "30 seconds")
        #expect(short.value == "0.00833333333333")
        #expect(short.detail.contains("30 seconds"))
        #expect(Clock.evaluate("from 1700000000 to 1700003725")?.result == "1 hour, 2 minutes, 5 seconds")
    }

    // MARK: Money and percentages

    @Test(arguments: [
        ("-100% vat in 120", Calculator.Issue.divisionByZero), ("120 incl -100% vat", .divisionByZero),
        ("remove -100% vat from 120", .divisionByZero), ("1e308% of 1e308", .resultOutOfRange),
        ("1e308 + 1e308% vat", .resultOutOfRange), ("1e300% tip on 1e300", .resultOutOfRange),
        ("1e308% off 1e308", .resultOutOfRange), ("1e308% increase on 1e308", .resultOutOfRange),
        ("what % of 1e-308 is 1e308", .resultOutOfRange),
    ])
    func nonfiniteMoneyAnswersAreIssues(input: String, expected: Calculator.Issue) {
        #expect(issue(input) == expected, "\(input)")
        #expect(Clock.evaluate(input) == nil)
    }

    // MARK: Number bases

    @Test(arguments: [
        ("9007199254740993 in hex", "0x20000000000001"), ("0x20000000000001 in dec", "9007199254740993"),
        ("18446744073709551615 in hex", "0xFFFFFFFFFFFFFFFF"), ("-0x10 in dec", "-16"), ("- 255 in hex", "-0xFF"),
        ("0 in bin", "0b0"), ("-0 in hex", "0x0"),
    ])
    func integersStayExact(input: String, expected: String) {
        #expect(Clock.evaluate(input)?.result == expected, "\(input)")
    }

    @Test func oversizedIntegersAreIssues() {
        #expect(issue("18446744073709551616 in hex") == .resultOutOfRange)
        #expect(issue("2^60 in hex") == .resultOutOfRange)
    }

    @Test(arguments: [("255 in hex", 16), ("255 in bin", 2), ("255 in oct", 8), ("0xff in dec", 10), ("0b1010 in hex", 16)])
    func standardRadicesRoundTrip(input: String, radix: Int) throws {
        let calculation = try #require(Clock.evaluate(input))
        let swapQuery = try #require(calculation.swapQuery)
        let back = try #require(Calculator.swapped(calculation, context: Clock.context()))
        let original = try NumberBases.exactInteger(String(input.split(separator: " ")[0]))
        let returned = try NumberBases.exactInteger(back.result)
        #expect(original.magnitude == returned.magnitude, "\(swapQuery)")
    }

    @Test func arbitraryRadicesHaveNoSwap() {
        #expect(Clock.evaluate("255 to base 7")?.swapQuery == nil)
        #expect(Clock.evaluate("35 in base 36")?.swapQuery == nil)
        #expect(Clock.evaluate("255 in dec")?.swapQuery == nil)
    }

    // MARK: Fractions

    @Test(arguments: [
        ("1000000000.5 as improper", "2000000001/2"), ("1000000000.25 as fraction", "1000000000 1/4"),
        ("2000000001/2 as improper", "2000000001/2"), ("123456789.75 as improper", "493827159/4"),
        ("0.1 + 0.2 as fraction", "≈ 3/10"), ("1/7 as fraction", "1/7"),
        ("100000000000000.03125 + 0 as improper", "3200000000000001/32"),
        ("999999999999999.5 + 0 as improper", "1999999999999999/2"),
        ("999999999999999.25 + 0 as improper", "3999999999999997/4"),
    ])
    func largeHalvesAndQuartersStayExact(input: String, expected: String) {
        #expect(Clock.evaluate(input)?.result == expected, "\(input)")
    }

    @Test func fractionLiteralsAreExact() {
        #expect(Fraction(decimalLiteral: "1000000000.5") == Fraction(numerator: 2_000_000_001, denominator: 2))
        #expect(Fraction(decimalLiteral: "-0.75") == Fraction(numerator: -3, denominator: 4))
        #expect(Fraction(decimalLiteral: "0.1234567891") == nil)
        #expect(Fraction(decimalLiteral: "1e3") == nil)
    }

    // MARK: Ambiguous words

    @Test(arguments: [
        "time", "now", "today", "tomorrow", "next friday", "timestamp", "unix time", "time in tokyo", "tokyo time",
        "week number", "pi", "e", "days until christmas", "how long until christmas",
    ])
    func wordsOnlyAnswersAreAmbiguous(_ input: String) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.isAmbiguous)
    }

    @Test(arguments: [
        "5pm ldn in sf", "50 + 20%", "days until 31 mar", "2 + 3", "√16", "10 km in mi", "monday in 3 weeks",
        "0xff", "€20 to $",
    ])
    func explicitMathIsNotAmbiguous(_ input: String) {
        let context = Clock.context(rates: try? CurrencyRatesTests.fixtureRates())
        #expect(Calculator.evaluate(input, context: context)?.isAmbiguous == false, "\(input)")
    }
}
