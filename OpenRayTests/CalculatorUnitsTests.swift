import Foundation
import Testing

@testable import OpenRay

struct CalculatorUnitsTests {
    private typealias Clock = CalculatorClock

    @Test(arguments: [
        ("16px in rem", "1 rem"), ("12pt in px", "16 px"), ("96 px in in", "1 in"), ("2 rem in px", "32 px"),
        ("1 pt in ml", "473.176 mL"), ("5 in in cm", "12.7 cm"), ("1 nmi in km", "1.852 km"),
        ("100 mbps in mb/s", "12.5 MB/s"), ("1 gbit in mb", "125 MB"), ("8 bits in bytes", "1 B"),
        ("1 acre in m2", "4046.86 m²"), ("1 sq ft in m²", "0.092903 m²"), ("1 ha in acres", "2.47105 acres"),
        ("60 mph in km/h", "96.5606 km/h"), ("10 m/s in kph", "36 km/h"), ("20 knots in mph", "23.0156 mph"),
        ("1 atm in psi", "14.6959 psi"), ("100 kpa in bar", "1 bar"), ("1013 hpa in inhg", "29.9139 inHg"),
        ("1 kwh in kj", "3600 kJ"), ("1 cal in j", "4.184 J"), ("2000 kcal in kwh", "2.32444 kWh"),
        ("1 hp in w", "745.7 W"), ("180 deg in rad", "3.14159 rad"), ("90° in turns", "0.25 turns"),
        ("1 ghz in mhz", "1000 MHz"), ("60 rpm in hz", "1 Hz"),
        ("2 cups in ml", "473.176 mL"), ("1 tbsp in tsp", "3 tsp"), ("1 cup in fl oz", "8 fl oz"),
        ("1 imp gal in l", "4.54609 L"), ("1 US gal in L", "3.78541 L"),
        ("1 t in lb", "2204.62 lb"), ("10 st in kg", "63.5029 kg"), ("1 fortnight in days", "14 days"),
        ("1 1/2 cups in ml", "354.882 mL"), ("100 c in rankine", "671.67 °R"),
    ])
    func convertsUnits(input: String, expected: String) {
        #expect(Clock.evaluate(input)?.result == expected, "\(input)")
    }

    @Test func remFollowsTheRootFontSize() {
        #expect(Clock.evaluate("1 rem in px", context: Clock.context(pixelsPerEm: 10))?.result == "10 px")
        #expect(Clock.evaluate("20px in em", context: Clock.context(pixelsPerEm: 10))?.result == "2 em")
    }

    @Test func ambiguousAliasesFollowTheOtherSide() throws {
        #expect(Clock.evaluate("1 pt in px")?.conversion?.source.name == "Points")
        #expect(Clock.evaluate("1 pt in ml")?.conversion?.source.name == "US Pints")
        #expect(Calculator.issue(for: "1 pt in kg", context: Clock.context()) == .incompatibleUnits)
    }

    @Test func relatedUnitsFollowTheFamily() throws {
        let cooking = try #require(Clock.evaluate("2 cups in ml")?.conversion)
        #expect(cooking.related.map(\.symbol) == ["tbsp", "tsp", "fl oz"])
        let css = try #require(Clock.evaluate("16px in rem")?.conversion)
        #expect(css.related.map(\.symbol) == ["pt", "em", "in", "mm"])
        let speed = try #require(Clock.evaluate("60 mph in km/h")?.conversion)
        #expect(speed.related.map(\.symbol) == ["m/s", "kn", "ft/s"])
    }

    @Test func everySymbolParsesBack() {
        for unit in UnitCatalog.all {
            #expect(UnitCatalog.units(named: unit.symbol).contains(unit), "\(unit.symbol)")
        }
    }

    @Test(arguments: [
        ("10 km in mi", "10 mi in km", "16.0934 km"),
        ("1 l in ml", "1 mL in L", "0.001 L"),
        ("100 f in c", "100 °C in °F", "212 °F"),
        ("1 gal in l", "1 L in US gal", "0.264172 US gal"),
        ("(2+3) km in m", "(2+3) m in km", "0.005 km"),
        ("1 sq ft in m2", "1 m² in ft²", "10.7639 ft²"),
    ])
    func swapUnits(input: String, swapQuery: String, swapped: String) throws {
        let calculation = try #require(Clock.evaluate(input))
        #expect(calculation.swapQuery == swapQuery)
        #expect(Calculator.swapped(calculation, context: Clock.context())?.result == swapped)
    }

    @Test(arguments: [
        ("a4 to hz", "440 Hz"), ("c4 to hz", "261.626 Hz"), ("bb3 in hz", "233.082 Hz"), ("c#5 to hz", "554.365 Hz"),
        ("440 hz to note", "A4"), ("445 hz to note", "A4 +20¢"), ("261.63 hz to note", "C4"),
    ])
    func musicNotes(input: String, expected: String) {
        #expect(Clock.evaluate(input)?.result == expected, "\(input)")
    }

    @Test(arguments: [
        ("50 + 20%", "60"), ("50 - 20%", "40"), ("200 * 15%", "30"), ("20%", "0.2"), ("50 + (20%)", "50.2"),
        ("0xff", "255"), ("0b1010 + 1", "11"), ("0o17", "15"), ("0xFF * 2", "510"),
        ("5!", "120"), ("3! + 1", "7"), ("10 mod 3", "1"), ("√16", "4"), ("√(9) + 1", "4"),
        ("log2(8)", "3"), ("cbrt(27)", "3"), ("exp(0)", "1"), ("atan(0)", "0"), ("cosh(0)", "1"),
        ("1 1/2 + 3/4", "2.25"), ("-1 1/2", "-1.5"),
    ])
    func arithmeticForms(input: String, expected: String) {
        #expect(Clock.evaluate(input)?.result == expected, "\(input)")
    }

    @Test(arguments: [
        ("asin(2)", Calculator.Issue.domainError), ("2.5!", .needsWholeNumber), ("171!", .resultOutOfRange),
        ("10 mod 0", .divisionByZero), ("2.5 in hex", .needsWholeNumber), ("√-4", .domainError),
    ])
    func arithmeticIssues(input: String, issue: Calculator.Issue) {
        #expect(Calculator.issue(for: input, context: Clock.context()) == issue)
    }

    @Test(arguments: [
        ("52% of 900", "468", "468"),
        ("20% off 80", "64", "64"),
        ("what % of 50 is 10", "20%", "20"),
        ("what percent of 50 is 10", "20%", "20"),
        ("10 is what % of 50", "20%", "20"),
        ("10 as a % of 50", "20%", "20"),
        ("1/8 is what %", "12.5%", "12.5"),
        ("0.25 as %", "25%", "25"),
        ("20% of what is 10", "50", "50"),
        ("10 is 20% of what", "50", "50"),
        ("% change from 50 to 60", "+20%", "20"),
        ("percent change from 80 to 60", "-25%", "-25"),
        ("20% on 80", "96", "96"),
        ("10% increase on 50", "55", "55"),
        ("15% decrease from 813", "691.05", "691.05"),
        ("15% tip on $80", "$92.00", "92.00"),
        ("tip 20% on 50", "60", "60"),
        ("15% tip on 80 split 4", "23", "23"),
        ("80 + 15% tip", "92", "92"),
        ("20% vat on 100", "120", "120"),
        ("add 20% vat to 100", "120", "120"),
        ("100 + 20% vat", "120", "120"),
        ("100 excl 20% vat", "120", "120"),
        ("100 with 20% vat", "120", "120"),
        ("20% vat in 120", "20", "20"),
        ("120 incl 20% vat", "100", "100"),
        ("120 - 20% vat", "100", "100"),
        ("remove 20% vat from 120", "100", "100"),
        ("8% sales tax on $25", "$27.00", "27.00"),
        ("20% discount on 80", "64", "64"),
        ("80 with 20% discount", "64", "64"),
        ("25% off $60 split 3", "$15.00", "15.00"),
        ("€50 - 10% off", "€45.00", "45.00"),
    ])
    func percentagePhrases(input: String, result: String, value: String) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.result == result)
        #expect(calculation.value == value)
        #expect(calculation.kind == .percentage)
    }

    @Test func moneyPhrasesExplainTheParts() throws {
        #expect(Clock.evaluate("15% tip on $80")?.detail == "Tip $12.00 · Total $92.00 · Return to copy")
        #expect(
            Clock.evaluate("25% off $60 split 3")?.detail
                == "Discount $15.00 · Was $60.00 · 3 ways of $45.00 · Return to copy")
        #expect(Clock.evaluate("120 incl 20% vat")?.detail == "Net · Tax 20 · Gross 120 · Return to copy")
    }

    @Test(arguments: ["10 tips to improve", "20% tip", "what % is it", "tip on 80"])
    func percentProseFallsThrough(_ input: String) {
        #expect(Clock.evaluate(input)?.kind != .percentage)
    }

    @Test(arguments: [
        ("255 in hex", "0xFF"), ("255 to hexadecimal", "0xFF"), ("255 to binary", "0b11111111"),
        ("8 in oct", "0o10"), ("0xff in dec", "255"), ("0b1111 in hex", "0xF"), ("255 to base 7", "513"),
        ("35 in base 36", "Z"), ("-255 in hex", "-0xFF"), ("16 * 16 in hex", "0x100"),
    ])
    func numberBases(input: String, expected: String) throws {
        let calculation = try #require(Clock.evaluate(input), "\(input)")
        #expect(calculation.result == expected)
        #expect(calculation.kind == .base)
    }

    @Test func basesSwapBackToTheirSource() throws {
        let hex = try #require(Clock.evaluate("255 in hex"))
        #expect(hex.swapQuery == "0xFF in dec")
        #expect(Calculator.swapped(hex, context: Clock.context())?.result == "255")
        #expect(Clock.evaluate("0xff in dec")?.swapQuery == "255 in hex")
    }

    @Test(arguments: [
        ("0.75 as fraction", "3/4"), ("1.75 as fraction", "1 3/4"), ("1.75 as improper", "7/4"),
        ("7/4 as mixed", "1 3/4"), ("1/3 + 1/6 as fraction", "1/2"), ("-1.25 as a fraction", "-1 1/4"),
        ("2 as fraction", "2"), ("0.333333333333 as fraction", "≈ 1/3"), ("1/3 as fraction", "1/3"), ("pi as improper fraction", "≈ 355/113"),
    ])
    func fractions(input: String, expected: String) {
        #expect(Clock.evaluate(input)?.result == expected, "\(input)")
    }

    @Test func fractionApproximation() throws {
        #expect(Fraction(approximating: 0.125) == Fraction(numerator: 1, denominator: 8))
        let pi = try #require(Fraction(approximating: .pi))
        #expect(pi.isExact == false)
        #expect(pi.improper == "355/113")
        #expect(pi.mixed == "3 16/113")
        #expect(Fraction(approximating: .infinity) == nil)
    }

    @Test func existingResultsKeepTheirKinds() {
        #expect(Clock.evaluate("2 + 3")?.kind == .arithmetic)
        #expect(Clock.evaluate("1 km in m")?.kind == .conversion)
        #expect(Clock.evaluate("1 km in m")?.detail == "Unit conversion · Return to copy")
        #expect(Clock.evaluate("2 + 3")?.detail == "Calculator · Return to copy")
    }
}

struct CalculatorHistoryTests {
    private let start = CalculatorClock.now

    private func calculation(_ input: String) -> Calculation {
        CalculatorClock.evaluate(input)!
    }

    @Test func addsNewestFirst() {
        var history = CalculatorHistory()
        history.add(calculation("2 + 3"), at: start)
        history.add(calculation("10 km in mi"), at: start.addingTimeInterval(60))
        #expect(history.entries.map(\.expression) == ["10 km in mi", "2 + 3"])
        #expect(history.entries.first?.value == "6.21371192237")
        #expect(history.entries.first?.kind == .conversion)
    }

    @Test func repeatsMoveToTheTopKeepingTheirID() throws {
        var history = CalculatorHistory()
        history.add(calculation("2 + 3"), at: start)
        let id = try #require(history.entries.first?.id)
        history.add(calculation("4 * 4"), at: start.addingTimeInterval(10))
        history.add(calculation("2  +  3"), at: start.addingTimeInterval(20))
        #expect(history.entries.count == 2)
        #expect(history.entries.first?.id == id)
        #expect(history.entries.first?.expression == "2  +  3")
        #expect(history.entries.first?.date == start.addingTimeInterval(20))
    }

    @Test func plainNumbersAreNotKept() {
        var history = CalculatorHistory()
        history.add(calculation("42"), at: start)
        #expect(history.isEmpty)
    }

    @Test func limitDropsTheOldest() {
        var history = CalculatorHistory(limit: 3)
        for value in 1...5 { history.add(calculation("\(value) + 1"), at: start.addingTimeInterval(Double(value))) }
        #expect(history.entries.map(\.expression) == ["5 + 1", "4 + 1", "3 + 1"])
    }

    @Test func pruneDropsEntriesOlderThanThreeMonths() {
        let calendar = CalculatorClock.calendar
        var history = CalculatorHistory()
        history.add(calculation("1 + 1"), at: calendar.date(byAdding: .month, value: -4, to: start)!)
        history.add(calculation("2 + 2"), at: calendar.date(byAdding: .month, value: -2, to: start)!)
        history.prune(now: start, calendar: calendar)
        #expect(history.entries.map(\.expression) == ["2 + 2"])
    }

    @Test func removeAndSearch() throws {
        var history = CalculatorHistory()
        history.add(calculation("10 km in mi"), at: start)
        history.add(calculation("2 + 3"), at: start)
        #expect(history.matching("KM").map(\.expression) == ["10 km in mi"])
        #expect(history.matching("6.21").map(\.expression) == ["10 km in mi"])
        #expect(history.matching("").count == 2)
        let id = try #require(history.entries.first?.id)
        history.remove(id: id)
        #expect(history.entries.map(\.expression) == ["10 km in mi"])
        history.removeAll()
        #expect(history.isEmpty)
    }

    @Test func roundTripsAndToleratesMissingFields() throws {
        var history = CalculatorHistory(limit: 50)
        history.add(calculation("10 km in mi"), at: start)
        let data = try JSONEncoder().encode(history)
        #expect(try JSONDecoder().decode(CalculatorHistory.self, from: data) == history)

        let sparse = Data(
            #"{"entries":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","expression":"1+1","result":"2","date":0}]}"#.utf8)
        let decoded = try JSONDecoder().decode(CalculatorHistory.self, from: sparse)
        #expect(decoded.limit == CalculatorHistory.defaultLimit)
        #expect(decoded.entries.first?.value == "2")
        #expect(decoded.entries.first?.kind == .arithmetic)
    }
}
