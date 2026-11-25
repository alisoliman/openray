import Foundation

/// "255 in hex", "0xff in dec", "255 to base 7".
enum NumberBases {
    static func evaluate(_ input: String, context: CalculatorContext) throws -> Calculation? {
        guard let groups = pattern.groups(in: input.lowercased()), let expression = groups[1], let target = groups[2]
        else { return nil }
        let radix: Int
        let name: String
        switch target {
        case "hex", "hexadecimal", "base 16", "base16": (radix, name) = (16, "Hexadecimal")
        case "bin", "binary", "base 2", "base2": (radix, name) = (2, "Binary")
        case "oct", "octal", "base 8", "base8": (radix, name) = (8, "Octal")
        case "dec", "decimal", "base 10", "base10": (radix, name) = (10, "Decimal")
        default:
            guard let digits = groups[3], let base = Int(digits), (2...36).contains(base) else { return nil }
            (radix, name) = (base, "Base \(base)")
        }
        let value = try Calculator.parse(expression)
        guard value == value.rounded() else { throw Calculator.Issue.needsWholeNumber }
        guard abs(value) <= 9_007_199_254_740_992 else { throw Calculator.Issue.resultOutOfRange }
        let integer = Int64(value)
        let shown = format(integer, radix: radix)
        let source = sourceBase(of: expression)
        return Calculation(
            expression: input, result: shown, detail: "\(name) · Return to copy", kind: .base,
            swapQuery: source.map { "\(shown) in \($0)" }, inputLabel: source == nil ? "Decimal" : nil,
            resultLabel: name)
    }

    /// Hex, binary and octal keep their prefix, so a copied value reads the same anywhere.
    static func format(_ value: Int64, radix: Int) -> String {
        let sign = value < 0 ? "-" : ""
        let digits = String(value.magnitude, radix: radix, uppercase: true)
        switch radix {
        case 16: return "\(sign)0x\(digits)"
        case 2: return "\(sign)0b\(digits)"
        case 8: return "\(sign)0o\(digits)"
        default: return sign + digits
        }
    }

    /// The base an input literal was written in, for Swap Units.
    private static func sourceBase(of expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("0x") { return "hex" }
        if trimmed.hasPrefix("0b") { return "bin" }
        if trimmed.hasPrefix("0o") { return "oct" }
        return trimmed.allSatisfy(\.isNumber) ? "dec" : nil
    }

    private static let pattern = CalculatorPattern(
        #"^(.+?)\s+(?:in|to|as|into)\s+(hex|hexadecimal|bin|binary|oct|octal|dec|decimal|base\s*(\d{1,2}))$"#)
}

/// "0.75 as fraction", "1.75 as improper", "7/4 as mixed".
enum Fractions {
    static func evaluate(_ input: String, context: CalculatorContext) throws -> Calculation? {
        guard let groups = pattern.groups(in: input.lowercased()), let expression = groups[1], let form = groups[2] else {
            return nil
        }
        let value = try Calculator.parse(expression)
        guard let fraction = Fraction(approximating: value) else { throw Calculator.Issue.resultOutOfRange }
        let improper = fraction.improper
        let mixed = fraction.mixed
        let shown = form.hasPrefix("improper") ? improper : mixed
        var detail = "Fraction"
        if !fraction.isExact { detail += " · Approximate" }
        if shown != improper { detail += " · \(improper)" } else if shown != mixed { detail += " · \(mixed)" }
        return Calculation(
            expression: input, result: (fraction.isExact ? "" : "≈ ") + shown, detail: detail + " · Return to copy",
            value: shown, kind: .fraction)
    }

    private static let pattern = CalculatorPattern(
        #"^(.+?)\s+(?:in|to|as|into)\s+(?:an?\s+)?(fractions?|mixed(?: numbers?| fractions?)?|improper(?: fractions?)?)$"#)
}

/// A reduced fraction close to a decimal, from its continued fraction.
struct Fraction: Equatable, Sendable {
    var numerator: Int64
    var denominator: Int64
    var isExact: Bool

    init(numerator: Int64, denominator: Int64, isExact: Bool = true) {
        self.numerator = numerator
        self.denominator = denominator
        self.isExact = isExact
    }

    /// Exact for decimals with up to six places and for simple fractions such as 1/3
    /// (a denominator up to 10,000, within 1e-9); otherwise the closest fraction with a
    /// denominator up to 10,000, marked inexact. Floating point can't tell π from a
    /// fraction with a huge denominator, so those are approximations, not answers.
    init?(approximating value: Double) {
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        if let decimal = Self.decimal(value) {
            self = decimal
            return
        }
        if let exact = Self.convergent(of: value, maxDenominator: 10_000, tolerance: 1e-9 * max(1, abs(value))) {
            self = exact
            return
        }
        guard var near = Self.convergent(of: value, maxDenominator: 10_000, tolerance: .infinity) else { return nil }
        near.isExact = false
        self = near
    }

    /// 1.75 → 7/4: a terminating decimal of up to six places, reduced.
    private static func decimal(_ value: Double) -> Fraction? {
        var denominator: Int64 = 1
        for _ in 0...6 {
            let scaled = value * Double(denominator)
            if abs(scaled - scaled.rounded()) <= 1e-9 * max(1, abs(scaled)), abs(scaled) < 9e15 {
                let numerator = Int64(scaled.rounded())
                let divisor = gcd(abs(numerator), denominator)
                return Fraction(numerator: numerator / divisor, denominator: denominator / divisor)
            }
            denominator *= 10
        }
        return nil
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        b == 0 ? max(a, 1) : gcd(b, a % b)
    }

    private static func convergent(of value: Double, maxDenominator: Int64, tolerance: Double) -> Fraction? {
        let sign: Int64 = value < 0 ? -1 : 1
        var x = abs(value)
        var (h0, h1): (Int64, Int64) = (0, 1)
        var (k0, k1): (Int64, Int64) = (1, 0)
        var best: Fraction?
        for _ in 0..<64 {
            let a = floor(x)
            guard a < 1e15 else { break }
            let term = Int64(a)
            let (h2, overflowH) = term.multipliedReportingOverflow(by: h1)
            let (k2, overflowK) = term.multipliedReportingOverflow(by: k1)
            guard !overflowH, !overflowK else { break }
            let h = h2 + h0
            let k = k2 + k0
            guard k <= maxDenominator else { break }
            (h0, h1) = (h1, h)
            (k0, k1) = (k1, k)
            best = Fraction(numerator: sign * h, denominator: k)
            if tolerance.isFinite, abs(Double(h) / Double(k) - abs(value)) <= tolerance { return best }
            let remainder = x - a
            guard remainder > 1e-15 else { return best }
            x = 1 / remainder
        }
        return tolerance.isInfinite ? best : nil
    }

    var improper: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }

    /// "1 3/4" for 7/4; a proper fraction stays as it is.
    var mixed: String {
        let whole = numerator / denominator
        let remainder = abs(numerator % denominator)
        guard whole != 0, remainder != 0 else { return improper }
        return "\(whole) \(remainder)/\(denominator)"
    }
}

/// Percentages, tips, VAT and discounts.
enum PercentPhrases {
    private typealias Issue = Calculator.Issue

    static func evaluate(_ input: String, context: CalculatorContext) throws -> Calculation? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.contains("%") || text.contains("percent") || text.contains("tip") else { return nil }
        let text2 = text.replacingOccurrences(of: "percent", with: "%").replacingOccurrences(of: "per cent", with: "%")
        for rule in rules {
            if let groups = rule.pattern.groups(in: text2) {
                return try rule.evaluate(Array(groups.dropFirst()), input)
            }
        }
        return nil
    }

    /// An amount with an optional currency sign, such as "$80" or "80 €".
    private struct Amount {
        var value: Double
        var sign: String?

        func format(_ number: Double) -> String {
            guard let sign else { return Calculator.format(number) }
            return sign + Calculator.format(number, fractionDigits: 2)
        }

        func copy(_ number: Double) -> String {
            sign == nil ? Calculator.format(number) : Calculator.format(number, fractionDigits: 2)
        }
    }

    private static let signs: [Character] = ["$", "€", "£", "¥", "₹", "₩", "₺", "₪", "₱", "฿"]

    private static func amount(_ text: String?) throws -> Amount {
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw Issue.incompleteExpression
        }
        var sign: String?
        if let first = text.first, signs.contains(first) {
            sign = String(first)
            text.removeFirst()
        } else if let last = text.last, signs.contains(last) {
            sign = String(last)
            text.removeLast()
        }
        return Amount(value: try Calculator.parse(text), sign: sign)
    }

    private static func number(_ text: String?) throws -> Double {
        guard let text, !text.isEmpty else { throw Issue.incompleteExpression }
        return try Calculator.parse(text)
    }

    private static func percent(_ text: String?) throws -> Double {
        try number(text) / 100
    }

    private struct Rule {
        var pattern: CalculatorPattern
        var evaluate: @Sendable ([String?], String) throws -> Calculation
    }

    private static func result(
        _ input: String, _ shown: String, value: String, detail: String, kind: Calculation.Kind = .percentage
    ) -> Calculation {
        Calculation(expression: input, result: shown, detail: "\(detail) · Return to copy", value: value, kind: kind)
    }

    private static func split(_ total: Double, _ people: String?, _ amount: Amount, _ detail: inout String) throws
        -> Double
    {
        guard let people else { return total }
        let count = try number(people)
        guard count >= 1, count == count.rounded() else { throw Issue.needsWholeNumber }
        detail += " · \(Calculator.format(count)) ways of \(amount.format(total))"
        return total / count
    }

    private static let splitSuffix = #"(?:\s+split(?:\s+(?:by|between|among|in))?\s+(.+?)(?:\s+ways|\s+people)?)?"#
    private static let tax = #"(?:vat|tax|sales tax|gst|mwst)"#

    private static let rules: [Rule] = [
        // "what % of 50 is 10" → 20%
        Rule(pattern: CalculatorPattern(#"^what\s*%\s*of\s+(.+?)\s+is\s+(.+)$"#)) { groups, input in
            let whole = try number(groups[0])
            guard whole != 0 else { throw Issue.divisionByZero }
            let share = try number(groups[1]) / whole * 100
            return result(input, "\(Calculator.format(share))%", value: Calculator.format(share), detail: "Percentage")
        },
        // "10 is what % of 50" / "10 as a % of 50" → 20%
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+(?:is\s+what|as\s+(?:a\s+)?)\s*%\s*of\s+(.+)$"#)) { groups, input in
            let whole = try number(groups[1])
            guard whole != 0 else { throw Issue.divisionByZero }
            let share = try number(groups[0]) / whole * 100
            return result(input, "\(Calculator.format(share))%", value: Calculator.format(share), detail: "Percentage")
        },
        // "1/8 is what %" / "0.25 as %" → 12.5%
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+(?:is\s+what|as\s+(?:a\s+)?|in|to)\s*%$"#)) { groups, input in
            let share = try number(groups[0]) * 100
            return result(input, "\(Calculator.format(share))%", value: Calculator.format(share), detail: "Percentage")
        },
        // "20% of what is 10" / "10 is 20% of what" → 50
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*of\s+what\s+is\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            guard rate != 0 else { throw Issue.divisionByZero }
            let whole = try number(groups[1]) / rate
            return result(input, Calculator.format(whole), value: Calculator.format(whole), detail: "Percentage")
        },
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+is\s+(.+?)\s*%\s*of\s+what$"#)) { groups, input in
            let rate = try percent(groups[1])
            guard rate != 0 else { throw Issue.divisionByZero }
            let whole = try number(groups[0]) / rate
            return result(input, Calculator.format(whole), value: Calculator.format(whole), detail: "Percentage")
        },
        // "% change from 50 to 60" → +20%
        Rule(pattern: CalculatorPattern(#"^%\s*(?:change|difference)\s+(?:from\s+)?(.+?)\s+to\s+(.+)$"#)) {
            groups, input in
            let from = try number(groups[0])
            guard from != 0 else { throw Issue.divisionByZero }
            let change = (try number(groups[1]) - from) / abs(from) * 100
            let shown = (change > 0 ? "+" : "") + Calculator.format(change) + "%"
            return result(input, shown, value: Calculator.format(change), detail: "Percentage change")
        },
        // "15% tip on $80 split 4"
        Rule(pattern: CalculatorPattern(#"^(?:(.+?)\s*%\s*tip|tip\s+(?:of\s+)?(.+?)\s*%)\s+(?:on|for|of)\s+(.+?)"# + splitSuffix + "$")) {
            groups, input in
            let rate = try percent(groups[0] ?? groups[1])
            let bill = try amount(groups[2])
            let tip = bill.value * rate
            var detail = "Tip \(bill.format(tip)) · Total \(bill.format(bill.value + tip))"
            let each = try split(bill.value + tip, groups[3], bill, &detail)
            return result(input, bill.format(each), value: bill.copy(each), detail: detail)
        },
        // "$80 + 15% tip"
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*(?:\+|plus|with)\s*(.+?)\s*%\s*tip"# + splitSuffix + "$")) {
            groups, input in
            let bill = try amount(groups[0])
            let tip = bill.value * (try percent(groups[1]))
            var detail = "Tip \(bill.format(tip)) · Total \(bill.format(bill.value + tip))"
            let each = try split(bill.value + tip, groups[2], bill, &detail)
            return result(input, bill.format(each), value: bill.copy(each), detail: detail)
        },
        // "20% vat in 120" → the VAT inside 120
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*"# + tax + #"\s+(?:in|of|included in|contained in)\s+(.+)$"#)) {
            groups, input in
            let rate = try percent(groups[0])
            let gross = try amount(groups[1])
            let net = gross.value / (1 + rate)
            return result(
                input, gross.format(gross.value - net), value: gross.copy(gross.value - net),
                detail: "Tax included · Net \(gross.format(net)) · Gross \(gross.format(gross.value))")
        },
        // "120 incl 20% vat" / "remove 20% vat from 120" / "120 - 20% vat" → net
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+(?:incl\.?|including|inc\.?|with|without|ex\.? |-|minus)\s*(.+?)\s*%\s*"# + tax + "(?:\\s+included)?$")) {
            groups, input in
            let rate = try percent(groups[1])
            let gross = try amount(groups[0])
            let net = gross.value / (1 + rate)
            if input.lowercased().contains("with "), !input.lowercased().contains("without") {
                return result(
                    input, gross.format(gross.value * (1 + rate)), value: gross.copy(gross.value * (1 + rate)),
                    detail: "Tax \(gross.format(gross.value * rate)) · Net \(gross.format(gross.value))")
            }
            return result(
                input, gross.format(net), value: gross.copy(net),
                detail: "Net · Tax \(gross.format(gross.value - net)) · Gross \(gross.format(gross.value))")
        },
        Rule(pattern: CalculatorPattern(#"^remove\s+(.+?)\s*%\s*"# + tax + #"\s+from\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            let gross = try amount(groups[1])
            let net = gross.value / (1 + rate)
            return result(
                input, gross.format(net), value: gross.copy(net),
                detail: "Net · Tax \(gross.format(gross.value - net)) · Gross \(gross.format(gross.value))")
        },
        // "20% vat on 100" / "add 20% vat to 100" / "100 + 20% vat" / "100 excl 20% vat" → gross
        Rule(pattern: CalculatorPattern(#"^(?:add\s+)?(.+?)\s*%\s*"# + tax + #"\s+(?:on|to|for)\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            let net = try amount(groups[1])
            return result(
                input, net.format(net.value * (1 + rate)), value: net.copy(net.value * (1 + rate)),
                detail: "Tax \(net.format(net.value * rate)) · Net \(net.format(net.value))")
        },
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*(?:\+|plus|excl\.?|excluding|exc\.?)\s*(.+?)\s*%\s*"# + tax + "$")) {
            groups, input in
            let rate = try percent(groups[1])
            let net = try amount(groups[0])
            return result(
                input, net.format(net.value * (1 + rate)), value: net.copy(net.value * (1 + rate)),
                detail: "Tax \(net.format(net.value * rate)) · Net \(net.format(net.value))")
        },
        // "20% off 80 split 3" / "20% discount on 80" / "80 with 20% discount" / "80 - 20% discount"
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*(?:off|discount\s+(?:on|off|from))\s+(.+?)"# + splitSuffix + "$")) {
            groups, input in
            let rate = try percent(groups[0])
            let price = try amount(groups[1])
            let saved = price.value * rate
            var detail = "Discount \(price.format(saved)) · Was \(price.format(price.value))"
            let each = try split(price.value - saved, groups[2], price, &detail)
            return result(input, price.format(each), value: price.copy(each), detail: detail)
        },
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*(?:with|-|minus|less)\s*(.+?)\s*%\s*(?:off|discount)$"#)) {
            groups, input in
            let rate = try percent(groups[1])
            let price = try amount(groups[0])
            let saved = price.value * rate
            return result(
                input, price.format(price.value - saved), value: price.copy(price.value - saved),
                detail: "Discount \(price.format(saved)) · Was \(price.format(price.value))")
        },
        // "15% decrease from 813" / "10% increase on 50" / "20% on 80"
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*(increase|decrease|more|less|on)\s+(?:from\s+|on\s+|of\s+|than\s+)?(.+)$"#)) {
            groups, input in
            let rate = try percent(groups[0])
            let base = try amount(groups[2])
            let down = groups[1] == "decrease" || groups[1] == "less"
            let total = base.value * (1 + (down ? -rate : rate))
            return result(
                input, base.format(total), value: base.copy(total),
                detail: "\(down ? "Down" : "Up") \(base.format(abs(total - base.value))) from \(base.format(base.value))")
        },
        // "52% of 900" → 468
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*of\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            let whole = try amount(groups[1])
            return result(input, whole.format(whole.value * rate), value: whole.copy(whole.value * rate), detail: "Percentage")
        },
    ]
}
