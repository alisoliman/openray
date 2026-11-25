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
        let integer = try exactInteger(expression)
        let shown = format(negative: integer.negative, magnitude: integer.magnitude, radix: radix)
        let source = sourceBase(of: expression)
        // A swap reads back only when the shown number carries its radix (0x, 0b, 0o) or is
        // decimal; "513" from base 7 would read as decimal, so it has no swap.
        let readable: [Int: String] = [16: "hex", 2: "bin", 8: "oct", 10: "dec"]
        let swap = source.flatMap { source in
            readable[radix].flatMap { $0 == source ? nil : "\(shown) in \(source)" }
        }
        return Calculation(
            expression: input, result: shown, detail: "\(name) · Return to copy", kind: .base, swapQuery: swap,
            inputLabel: source == nil ? "Decimal" : nil, resultLabel: name)
    }

    /// An integer read exactly. A literal ("9007199254740993", "0x20000000000001") is read
    /// in integer space, up to 64 bits; any other expression must evaluate to a whole
    /// number a Double holds exactly (up to 2^53).
    static func exactInteger(_ expression: String) throws -> (negative: Bool, magnitude: UInt64) {
        var body = Substring(expression.trimmingCharacters(in: .whitespaces).lowercased())
        var negative = false
        if body.first == "-" || body.first == "+" {
            negative = body.first == "-"
            body = body.dropFirst().drop(while: \.isWhitespace)
        }
        var radix = 10
        for (prefix, base) in [("0x", 16), ("0b", 2), ("0o", 8)] where body.hasPrefix(prefix) {
            radix = base
            body = body.dropFirst(2)
        }
        if !body.isEmpty, body.allSatisfy({ Int(String($0), radix: radix) != nil }) {
            guard let magnitude = UInt64(body, radix: radix) else { throw Calculator.Issue.resultOutOfRange }
            return (negative && magnitude != 0, magnitude)
        }
        let value = try Calculator.parse(expression)
        guard value == value.rounded() else { throw Calculator.Issue.needsWholeNumber }
        guard abs(value) <= 9_007_199_254_740_992 else { throw Calculator.Issue.resultOutOfRange }
        return (value < 0, UInt64(abs(value)))
    }

    /// Hex, binary and octal keep their prefix, so a copied value reads the same anywhere.
    static func format(negative: Bool, magnitude: UInt64, radix: Int) -> String {
        let sign = negative ? "-" : ""
        let digits = String(magnitude, radix: radix, uppercase: true)
        switch radix {
        case 16: return "\(sign)0x\(digits)"
        case 2: return "\(sign)0b\(digits)"
        case 8: return "\(sign)0o\(digits)"
        default: return sign + digits
        }
    }

    /// The base an input literal was written in, for Swap Units.
    private static func sourceBase(of expression: String) -> String? {
        var trimmed = Substring(expression.trimmingCharacters(in: .whitespaces).lowercased())
        if trimmed.first == "-" || trimmed.first == "+" { trimmed = trimmed.dropFirst() }
        if trimmed.hasPrefix("0x") { return "hex" }
        if trimmed.hasPrefix("0b") { return "bin" }
        if trimmed.hasPrefix("0o") { return "oct" }
        return !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber) ? "dec" : nil
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
        let fraction: Fraction
        if let literal = Fraction(decimalLiteral: expression) {
            fraction = literal
        } else {
            let value = try Calculator.parse(expression)
            guard let approximation = Fraction(approximating: value) else { throw Calculator.Issue.resultOutOfRange }
            fraction = approximation
        }
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
        let divisor = Self.gcd(numerator.magnitude, denominator.magnitude)
        self.numerator = numerator / Int64(divisor)
        self.denominator = denominator / Int64(divisor)
        self.isExact = isExact
    }

    /// The exact value of a typed decimal such as "1000000000.5", up to nine decimal
    /// places and 18 digits; nil for anything else.
    init?(decimalLiteral text: String) {
        guard let groups = Self.literal.groups(in: text.trimmingCharacters(in: .whitespaces)),
            let whole = groups[2]
        else { return nil }
        let decimals = groups[3] ?? ""
        guard decimals.count <= 9, whole.count + decimals.count <= 18,
            let digits = Int64(whole + decimals)
        else { return nil }
        var denominator: Int64 = 1
        for _ in 0..<decimals.count { denominator *= 10 }
        self.init(numerator: groups[1] == "-" ? -digits : digits, denominator: denominator)
    }

    /// Exact when a short decimal or a simple fraction (a denominator up to 10,000) matches
    /// the value to within a few units in the last place, which is all a computed Double can
    /// promise; otherwise the closest fraction with a denominator up to 10,000, marked
    /// inexact. Floating point can't tell π from a fraction with a huge denominator.
    init?(approximating value: Double) {
        guard value.isFinite, abs(value) < 1e15 else { return nil }
        if let decimal = Self.decimal(value) {
            self = decimal
            return
        }
        if let exact = Self.convergent(of: value, maxDenominator: 10_000, tolerance: 8 * value.ulp) {
            self = exact
            return
        }
        guard var near = Self.convergent(of: value, maxDenominator: 10_000, tolerance: .infinity) else { return nil }
        near.isExact = false
        self = near
    }

    /// 1.75 → 7/4: a terminating decimal of up to six places, reduced. The tolerance is a
    /// few units in the last place, so 1000000000.5 never passes as 1000000001.
    private static func decimal(_ value: Double) -> Fraction? {
        var denominator: Int64 = 1
        for _ in 0...6 {
            let scaled = value * Double(denominator)
            guard abs(scaled) < 9e15 else { return nil }
            if abs(scaled - scaled.rounded()) <= 4 * scaled.ulp {
                return Fraction(numerator: Int64(scaled.rounded()), denominator: denominator)
            }
            denominator *= 10
        }
        return nil
    }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        b == 0 ? max(a, 1) : gcd(b, a % b)
    }

    private static let literal = CalculatorPattern(#"^([+-]?)(\d+)(?:\.(\d+))?$"#)

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
            guard remainder > 1e-15 else { break }
            x = 1 / remainder
        }
        guard let best else { return nil }
        if tolerance.isInfinite { return best }
        let error = abs(Double(best.numerator.magnitude) / Double(best.denominator) - abs(value))
        return error <= tolerance ? best : nil
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

    /// Throws the arithmetic parser's issues for answers it would never produce: NaN is a
    /// domain error and infinity is out of range.
    private static func checked(_ values: Double...) throws {
        for value in values {
            if value.isNaN { throw Issue.domainError }
            if !value.isFinite { throw Issue.resultOutOfRange }
        }
    }

    /// The amount before a tax or markup of `rate` was added; a rate of −100% has none.
    private static func removingTax(from gross: Double, rate: Double) throws -> Double {
        guard 1 + rate != 0 else { throw Issue.divisionByZero }
        let net = gross / (1 + rate)
        try checked(net, gross - net)
        return net
    }

    private static let rules: [Rule] = [
        // "what % of 50 is 10" → 20%
        Rule(pattern: CalculatorPattern(#"^what\s*%\s*of\s+(.+?)\s+is\s+(.+)$"#)) { groups, input in
            let whole = try number(groups[0])
            guard whole != 0 else { throw Issue.divisionByZero }
            let share = try number(groups[1]) / whole * 100
            try checked(share)
            return result(input, "\(Calculator.format(share))%", value: Calculator.format(share), detail: "Percentage")
        },
        // "10 is what % of 50" / "10 as a % of 50" → 20%
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+(?:is\s+what|as\s+(?:a\s+)?)\s*%\s*of\s+(.+)$"#)) { groups, input in
            let whole = try number(groups[1])
            guard whole != 0 else { throw Issue.divisionByZero }
            let share = try number(groups[0]) / whole * 100
            try checked(share)
            return result(input, "\(Calculator.format(share))%", value: Calculator.format(share), detail: "Percentage")
        },
        // "1/8 is what %" / "0.25 as %" → 12.5%
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+(?:is\s+what|as\s+(?:a\s+)?|in|to)\s*%$"#)) { groups, input in
            let share = try number(groups[0]) * 100
            try checked(share)
            return result(input, "\(Calculator.format(share))%", value: Calculator.format(share), detail: "Percentage")
        },
        // "20% of what is 10" / "10 is 20% of what" → 50
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*of\s+what\s+is\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            guard rate != 0 else { throw Issue.divisionByZero }
            let whole = try number(groups[1]) / rate
            try checked(whole)
            return result(input, Calculator.format(whole), value: Calculator.format(whole), detail: "Percentage")
        },
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+is\s+(.+?)\s*%\s*of\s+what$"#)) { groups, input in
            let rate = try percent(groups[1])
            guard rate != 0 else { throw Issue.divisionByZero }
            let whole = try number(groups[0]) / rate
            try checked(whole)
            return result(input, Calculator.format(whole), value: Calculator.format(whole), detail: "Percentage")
        },
        // "% change from 50 to 60" → +20%
        Rule(pattern: CalculatorPattern(#"^%\s*(?:change|difference)\s+(?:from\s+)?(.+?)\s+to\s+(.+)$"#)) {
            groups, input in
            let from = try number(groups[0])
            guard from != 0 else { throw Issue.divisionByZero }
            let change = (try number(groups[1]) - from) / abs(from) * 100
            try checked(change)
            let shown = (change > 0 ? "+" : "") + Calculator.format(change) + "%"
            return result(input, shown, value: Calculator.format(change), detail: "Percentage change")
        },
        // "15% tip on $80 split 4"
        Rule(pattern: CalculatorPattern(#"^(?:(.+?)\s*%\s*tip|tip\s+(?:of\s+)?(.+?)\s*%)\s+(?:on|for|of)\s+(.+?)"# + splitSuffix + "$")) {
            groups, input in
            let rate = try percent(groups[0] ?? groups[1])
            let bill = try amount(groups[2])
            let tip = bill.value * rate
            try checked(tip, bill.value + tip)
            var detail = "Tip \(bill.format(tip)) · Total \(bill.format(bill.value + tip))"
            let each = try split(bill.value + tip, groups[3], bill, &detail)
            return result(input, bill.format(each), value: bill.copy(each), detail: detail)
        },
        // "$80 + 15% tip"
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*(?:\+|plus|with)\s*(.+?)\s*%\s*tip"# + splitSuffix + "$")) {
            groups, input in
            let bill = try amount(groups[0])
            let tip = bill.value * (try percent(groups[1]))
            try checked(tip, bill.value + tip)
            var detail = "Tip \(bill.format(tip)) · Total \(bill.format(bill.value + tip))"
            let each = try split(bill.value + tip, groups[2], bill, &detail)
            return result(input, bill.format(each), value: bill.copy(each), detail: detail)
        },
        // "20% vat in 120" → the VAT inside 120
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*"# + tax + #"\s+(?:in|of|included in|contained in)\s+(.+)$"#)) {
            groups, input in
            let rate = try percent(groups[0])
            let gross = try amount(groups[1])
            let net = try removingTax(from: gross.value, rate: rate)
            return result(
                input, gross.format(gross.value - net), value: gross.copy(gross.value - net),
                detail: "Tax included · Net \(gross.format(net)) · Gross \(gross.format(gross.value))")
        },
        // "120 incl 20% vat" / "120 - 20% vat" → net; "120 with 20% vat" → gross
        Rule(pattern: CalculatorPattern(#"^(.+?)\s+(?:incl\.?|including|inc\.?|with|without|ex\.? |-|minus)\s*(.+?)\s*%\s*"# + tax + "(?:\\s+included)?$")) {
            groups, input in
            let rate = try percent(groups[1])
            let gross = try amount(groups[0])
            if input.lowercased().contains("with "), !input.lowercased().contains("without") {
                let total = gross.value * (1 + rate)
                try checked(total, gross.value * rate)
                return result(
                    input, gross.format(total), value: gross.copy(total),
                    detail: "Tax \(gross.format(gross.value * rate)) · Net \(gross.format(gross.value))")
            }
            let net = try removingTax(from: gross.value, rate: rate)
            return result(
                input, gross.format(net), value: gross.copy(net),
                detail: "Net · Tax \(gross.format(gross.value - net)) · Gross \(gross.format(gross.value))")
        },
        Rule(pattern: CalculatorPattern(#"^remove\s+(.+?)\s*%\s*"# + tax + #"\s+from\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            let gross = try amount(groups[1])
            let net = try removingTax(from: gross.value, rate: rate)
            return result(
                input, gross.format(net), value: gross.copy(net),
                detail: "Net · Tax \(gross.format(gross.value - net)) · Gross \(gross.format(gross.value))")
        },
        // "20% vat on 100" / "add 20% vat to 100" / "100 + 20% vat" / "100 excl 20% vat" → gross
        Rule(pattern: CalculatorPattern(#"^(?:add\s+)?(.+?)\s*%\s*"# + tax + #"\s+(?:on|to|for)\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            let net = try amount(groups[1])
            let total = net.value * (1 + rate)
            try checked(total, net.value * rate)
            return result(
                input, net.format(total), value: net.copy(total),
                detail: "Tax \(net.format(net.value * rate)) · Net \(net.format(net.value))")
        },
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*(?:\+|plus|excl\.?|excluding|exc\.?)\s*(.+?)\s*%\s*"# + tax + "$")) {
            groups, input in
            let rate = try percent(groups[1])
            let net = try amount(groups[0])
            let total = net.value * (1 + rate)
            try checked(total, net.value * rate)
            return result(
                input, net.format(total), value: net.copy(total),
                detail: "Tax \(net.format(net.value * rate)) · Net \(net.format(net.value))")
        },
        // "20% off 80 split 3" / "20% discount on 80" / "80 with 20% discount" / "80 - 20% discount"
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*(?:off|discount\s+(?:on|off|from))\s+(.+?)"# + splitSuffix + "$")) {
            groups, input in
            let rate = try percent(groups[0])
            let price = try amount(groups[1])
            let saved = price.value * rate
            try checked(saved, price.value - saved)
            var detail = "Discount \(price.format(saved)) · Was \(price.format(price.value))"
            let each = try split(price.value - saved, groups[2], price, &detail)
            return result(input, price.format(each), value: price.copy(each), detail: detail)
        },
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*(?:with|-|minus|less)\s*(.+?)\s*%\s*(?:off|discount)$"#)) {
            groups, input in
            let rate = try percent(groups[1])
            let price = try amount(groups[0])
            let saved = price.value * rate
            try checked(saved, price.value - saved)
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
            try checked(total, total - base.value)
            return result(
                input, base.format(total), value: base.copy(total),
                detail: "\(down ? "Down" : "Up") \(base.format(abs(total - base.value))) from \(base.format(base.value))")
        },
        // "52% of 900" → 468
        Rule(pattern: CalculatorPattern(#"^(.+?)\s*%\s*of\s+(.+)$"#)) { groups, input in
            let rate = try percent(groups[0])
            let whole = try amount(groups[1])
            try checked(whole.value * rate)
            return result(input, whole.format(whole.value * rate), value: whole.copy(whole.value * rate), detail: "Percentage")
        },
    ]
}
