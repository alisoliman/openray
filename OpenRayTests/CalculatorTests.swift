import Testing

@testable import OpenRay

struct CalculatorTests {
    @Test func tinyNonzeroResultsAreNotRoundedToZero() throws {
        let result = try #require(Calculator.evaluate("1e-15")?.result)
        #expect(Double(result) == 1e-15)
    }

    @Test(arguments: [
        ("2 + 3 * 4", "14"), ("(2 + 3) * 4", "20"), ("-2^2", "-4"),
        ("2^3^2", "512"), ("2^-3", "0.125"), ("200 * 15%", "30"),
        ("sqrt(144)", "12"), ("abs(-5)", "5"), ("round(2.6)", "3"),
        ("floor(2.9)", "2"), ("ceil(2.1)", "3"), ("log(100)", "2"),
        ("sin(0)", "0"), ("cos(0)", "1"), ("ln(e)", "1"),
        ("1e3 + 1.5", "1001.5"), ("1e-3", "0.001"), ("6 × 7", "42"),
        ("8 ÷ 2", "4"), ("0.1 + 0.2", "0.3"), ("−3 + 3", "0"),
    ])
    func arithmetic(input: String, expected: String) {
        #expect(Calculator.evaluate(input)?.result == expected)
    }

    @Test(arguments: [
        ("1 km in m", "1000 m"), ("12 inches to ft", "1 ft"),
        ("2 hours in min", "120 min"), ("1 kg to g", "1000 g"),
        ("32 f in c", "0 °C"), ("100 c in f", "212 °F"),
        ("0 k to c", "-273.15 °C"), ("1 gib in mib", "1024 MiB"),
        ("1 GB in MB", "1000 MB"), ("(2+3) km in m", "5000 m"),
        ("1 l in ml", "1000 mL"), ("1 week in days", "7 days"),
    ])
    func unitConversions(input: String, expected: String) {
        #expect(Calculator.evaluate(input)?.result == expected)
    }

    @Test(arguments: [
        "", "Safari", "1/0", "sqrt(-1)", "2 +", "(2+3", "2) + 3", "1..2", "1e", "2 ** 3", "2 kg to km", "50 USD to EUR",
        "random(5)", "1; exit", "1e999", "NaN", "2 + 3 garbage",
        String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100),
    ])
    func rejectsInvalidOrUnsafeInput(_ input: String) {
        #expect(Calculator.evaluate(input) == nil)
    }
}
