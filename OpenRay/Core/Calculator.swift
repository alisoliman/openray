import Foundation

struct Calculation: Equatable, Sendable {
    struct Quantity: Equatable, Sendable {
        /// The number as shown. Related units use a compact, grouped form.
        var value: String
        var symbol: String
        var name: String
        /// The ungrouped number, up to 12 significant digits, that copying uses.
        var copyValue: String

        init(value: String, symbol: String, name: String, copyValue: String? = nil) {
            self.value = value
            self.symbol = symbol
            self.name = name
            self.copyValue = copyValue ?? value
        }
    }

    struct Conversion: Equatable, Sendable {
        var source: Quantity
        var target: Quantity
        /// The same amount in other units of the same dimension, for copying.
        var related: [Quantity]
    }

    var expression: String
    var result: String
    var detail: String
    /// The result without its unit. Return copies this.
    var value: String
    var conversion: Conversion? = nil

    /// The number as shown. A conversion shows six significant digits and copies all of them.
    var shownValue: String { conversion?.target.value ?? value }

    init(expression: String, result: String, detail: String, value: String? = nil, conversion: Conversion? = nil) {
        self.expression = expression
        self.result = result
        self.detail = detail
        self.value = value ?? result
        self.conversion = conversion
    }
}

enum Calculator {
    enum Issue: Error, Equatable, Sendable {
        case incompleteExpression
        case divisionByZero
        case domainError
        case unsupportedCurrencyConversion
        case unsupportedConversion
        case incompatibleUnits
        case invalidExpression
        case resultOutOfRange
        case expressionTooComplex

        var title: String {
            switch self {
            case .incompleteExpression: "Finish the expression"
            case .divisionByZero: "Can't divide by zero"
            case .domainError: "There's no real-number result"
            case .unsupportedCurrencyConversion: "Currency conversion isn't supported"
            case .unsupportedConversion: "That unit isn't supported"
            case .incompatibleUnits: "These units don't match"
            case .invalidExpression: "Check the expression"
            case .resultOutOfRange: "The result is too large"
            case .expressionTooComplex: "Simplify the expression"
            }
        }

        var message: String {
            switch self {
            case .incompleteExpression:
                "Add the missing number, closing parenthesis or target unit."
            case .divisionByZero:
                "The divisor is zero, so there's no result. Check the divisor."
            case .domainError:
                "Use a nonnegative value for sqrt, a positive value for log or ln, and powers with a real result."
            case .unsupportedCurrencyConversion:
                "OpenRay converts length, mass, time, temperature, volume and storage on this Mac, without a network rate source."
            case .unsupportedConversion:
                "Try supported units, such as 10 km in mi, 72 f in c or 1 GiB in MiB."
            case .incompatibleUnits:
                "Convert between units of the same kind, such as kg to lb or km to mi."
            case .invalidExpression:
                "Use numbers, + − × ÷ %, powers, parentheses or functions such as sqrt(144)."
            case .resultOutOfRange:
                "Try smaller numbers, or break the calculation into steps."
            case .expressionTooComplex:
                "Use fewer than 513 characters, with fewer nested parentheses or signs."
            }
        }

        /// Issues specific enough to show while searching Everything.
        var isWorthShowingInSearch: Bool {
            switch self {
            case .divisionByZero, .domainError, .unsupportedCurrencyConversion, .incompatibleUnits,
                .resultOutOfRange, .unsupportedConversion:
                true
            default: false
            }
        }
    }

    /// An issue to show in place of a result, only when the input clearly is math.
    static func searchIssue(for input: String) -> Issue? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isNumber || first == "(" || first == "-" || first == "√",
            trimmed.count >= 3, let issue = issue(for: trimmed), issue.isWorthShowingInSearch
        else { return nil }
        if issue == .unsupportedConversion {
            // Prose such as "2 days to go" has the same shape. Only an unknown unit
            // converted into a known one, as in "1 parsec in m", is clearly a conversion.
            guard let tokens = conversionTokens(in: normalized(trimmed)), let target = tokens.target,
                units[target] != nil, units[tokens.source] == nil
            else { return nil }
        }
        return issue
    }

    static func issue(for input: String) -> Issue? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try calculate(input)
            return nil
        } catch let issue as Issue {
            return issue
        } catch {
            return .invalidExpression
        }
    }

    static func evaluate(_ input: String) -> Calculation? {
        try? calculate(input)
    }

    private static func calculate(_ input: String) throws -> Calculation {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw Issue.incompleteExpression }
        guard input.count <= 512 else { throw Issue.expressionTooComplex }
        let normalized = Self.normalized(input)
        if var conversion = try convert(normalized) {
            conversion.expression = input
            return conversion
        }
        var parser = ExpressionParser(normalized)
        let value = try parser.parse()
        return Calculation(expression: input, result: format(value), detail: "Calculator · Return to copy")
    }

    private static func normalized(_ input: String) -> String {
        input.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi")
    }

    /// A compact, grouped form for display-only values such as related units.
    static func displayFormat(_ number: Double) -> String {
        number.formatted(
            .number.locale(Locale(identifier: "en_US")).precision(.significantDigits(1...shownDigits(number))))
    }

    /// A conversion's headline: six significant digits, ungrouped like `format`.
    static func conversionFormat(_ number: Double) -> String {
        let number = number == 0 ? 0 : number
        return number.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.significantDigits(1...shownDigits(number))))
    }

    /// Six significant digits, but never fewer than the whole-number digits (up to
    /// `format`'s twelve), so shortening only ever drops decimals.
    private static func shownDigits(_ number: Double) -> Int {
        let magnitude = abs(number)
        guard magnitude >= 1, magnitude.isFinite else { return 6 }
        return min(max(6, Int(log10(magnitude).rounded(.down)) + 1), 12)
    }

    static func format(_ number: Double) -> String {
        let number = number == 0 ? 0 : number
        return number.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.significantDigits(1...12)))
    }

    private struct Unit {
        var dimension: String
        var scale: Double
        var offset: Double = 0
        var symbol: String

        var name: String { Calculator.unitNames[symbol] ?? symbol }
    }

    private static let unitNames: [String: String] = [
        "m": "Meters", "km": "Kilometers", "cm": "Centimeters", "mm": "Millimeters", "mi": "Miles", "ft": "Feet",
        "in": "Inches", "yd": "Yards", "kg": "Kilograms", "g": "Grams", "lb": "Pounds", "oz": "Ounces",
        "s": "Seconds", "min": "Minutes", "h": "Hours", "days": "Days", "weeks": "Weeks", "B": "Bytes",
        "KB": "Kilobytes", "MB": "Megabytes", "GB": "Gigabytes", "TB": "Terabytes", "KiB": "Kibibytes",
        "MiB": "Mebibytes", "GiB": "Gibibytes", "°C": "Celsius", "°F": "Fahrenheit", "K": "Kelvin",
        "L": "Liters", "mL": "Milliliters", "US gal": "US Gallons",
    ]

    /// Related units shown under a conversion, in a familiar order per dimension.
    private static let relatedOrder: [String: [String]] = [
        "length": ["ft", "m", "yd", "km", "mi", "cm", "in"],
        "mass": ["g", "kg", "lb", "oz"],
        "time": ["min", "h", "s", "days", "weeks"],
        "storage": ["MB", "GB", "MiB", "GiB", "KB", "TB"],
        "temperature": ["°C", "°F", "K"],
        "volume": ["mL", "L", "US gal"],
    ]

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ aliases: [String], _ dimension: String, _ scale: Double, _ symbol: String, offset: Double = 0) {
            for alias in aliases {
                result[alias] = Unit(dimension: dimension, scale: scale, offset: offset, symbol: symbol)
            }
        }
        add(["m", "meter", "meters", "metre", "metres"], "length", 1, "m")
        add(["km", "kilometer", "kilometers", "kilometres"], "length", 1_000, "km")
        add(["cm", "centimeter", "centimeters"], "length", 0.01, "cm")
        add(["mm", "millimeter", "millimeters"], "length", 0.001, "mm")
        add(["mi", "mile", "miles"], "length", 1_609.344, "mi")
        add(["ft", "foot", "feet"], "length", 0.3048, "ft")
        add(["in", "inch", "inches"], "length", 0.0254, "in")
        add(["yd", "yard", "yards"], "length", 0.9144, "yd")
        add(["kg", "kilogram", "kilograms"], "mass", 1, "kg")
        add(["g", "gram", "grams"], "mass", 0.001, "g")
        add(["lb", "lbs", "pound", "pounds"], "mass", 0.45359237, "lb")
        add(["oz", "ounce", "ounces"], "mass", 0.028349523125, "oz")
        add(["s", "sec", "second", "seconds"], "time", 1, "s")
        add(["min", "minute", "minutes"], "time", 60, "min")
        add(["h", "hr", "hour", "hours"], "time", 3_600, "h")
        add(["day", "days"], "time", 86_400, "days")
        add(["week", "weeks"], "time", 604_800, "weeks")
        add(["b", "byte", "bytes"], "storage", 1, "B")
        add(["kb"], "storage", 1_000, "KB")
        add(["mb"], "storage", 1_000_000, "MB")
        add(["gb"], "storage", 1_000_000_000, "GB")
        add(["tb"], "storage", 1_000_000_000_000, "TB")
        add(["kib"], "storage", 1_024, "KiB")
        add(["mib"], "storage", 1_048_576, "MiB")
        add(["gib"], "storage", 1_073_741_824, "GiB")
        add(["c", "°c", "celsius"], "temperature", 1, "°C", offset: 273.15)
        add(["f", "°f", "fahrenheit"], "temperature", 5.0 / 9, "°F", offset: 255.3722222222222)
        add(["k", "kelvin"], "temperature", 1, "K")
        add(["l", "liter", "liters", "litres"], "volume", 1, "L")
        add(["ml", "milliliter", "milliliters"], "volume", 0.001, "mL")
        add(["gal", "gallon", "gallons"], "volume", 3.785411784, "US gal")
        return result
    }()

    private static let currencyUnits = Set(Locale.commonISOCurrencyCodes.map { $0.lowercased() })
        .union(["$", "€", "£", "¥", "₹", "dollar", "dollars", "euro", "euros", "yen"])

    /// The parts of "<expression> <unit> in|to|as <unit>". Unit names are lowercased.
    private struct ConversionTokens {
        var expression: String
        var source: String
        var target: String?
    }

    private static func conversionTokens(in input: String) -> ConversionTokens? {
        let pattern = #"^(.+?)\s*([\p{L}°\p{Sc}]+)\s+(?:in|to|as)(?:\s+([\p{L}°\p{Sc}]+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
            let expressionRange = Range(match.range(at: 1), in: input),
            let sourceRange = Range(match.range(at: 2), in: input)
        else { return nil }
        return ConversionTokens(
            expression: String(input[expressionRange]), source: input[sourceRange].lowercased(),
            target: Range(match.range(at: 3), in: input).map { input[$0].lowercased() })
    }

    private static func convert(_ input: String) throws -> Calculation? {
        guard let tokens = conversionTokens(in: input) else { return nil }
        var parser = ExpressionParser(tokens.expression)
        let number = try parser.parse()
        guard let targetName = tokens.target else { throw Issue.incompleteExpression }
        let sourceName = tokens.source
        if currencyUnits.contains(sourceName) || currencyUnits.contains(targetName) {
            throw Issue.unsupportedCurrencyConversion
        }
        guard let source = units[sourceName], let target = units[targetName] else {
            throw Issue.unsupportedConversion
        }
        guard source.dimension == target.dimension else { throw Issue.incompatibleUnits }
        let result = (number * source.scale + source.offset - target.offset) / target.scale
        guard result.isFinite else { throw Issue.resultOutOfRange }
        let base = number * source.scale + source.offset
        let symbolUnits = Dictionary(units.values.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let related = (relatedOrder[source.dimension] ?? [])
            .filter { $0 != source.symbol && $0 != target.symbol }
            .compactMap { symbol -> Calculation.Quantity? in
                guard let unit = symbolUnits[symbol] else { return nil }
                let value = (base - unit.offset) / unit.scale
                guard value.isFinite else { return nil }
                return .init(
                    value: displayFormat(value), symbol: unit.symbol, name: unit.name, copyValue: format(value))
            }
            .prefix(4)
        return Calculation(
            expression: input, result: "\(conversionFormat(result)) \(target.symbol)",
            detail: "Unit conversion · Return to copy", value: format(result),
            conversion: .init(
                source: .init(value: format(number), symbol: source.symbol, name: source.name),
                target: .init(
                    value: conversionFormat(result), symbol: target.symbol, name: target.name, copyValue: format(result)),
                related: Array(related)))
    }
}

/// A bounded arithmetic grammar, never an expression evaluator or shell interpreter.
private struct ExpressionParser {
    private typealias Issue = Calculator.Issue
    private let characters: [Character]
    private var index = 0
    private var depth = 0

    init(_ input: String) { characters = Array(input.lowercased()) }

    mutating func parse() throws -> Double {
        let result = try expression()
        skipSpaces()
        guard index == characters.count else { throw Issue.invalidExpression }
        return try checked(result)
    }

    private mutating func expression() throws -> Double {
        var result = try product()
        while true {
            if consume("+") {
                result = try checked(result + product())
            } else if consume("-") {
                result = try checked(result - product())
            } else {
                return result
            }
        }
    }

    private mutating func product() throws -> Double {
        var result = try unary()
        while true {
            if consume("*") {
                result = try checked(result * unary())
            } else if consume("/") {
                let divisor = try unary()
                guard divisor != 0 else { throw Issue.divisionByZero }
                result = try checked(result / divisor)
            } else {
                return result
            }
        }
    }

    private mutating func unary() throws -> Double {
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw Issue.expressionTooComplex }
        if consume("+") { return try unary() }
        if consume("-") { return try -unary() }
        var result = try primary()
        while consume("%") { result /= 100 }
        if consume("^") {
            let exponent = try unary()
            guard result != 0 || exponent >= 0 else { throw Issue.divisionByZero }
            result = try checked(pow(result, exponent))
        }
        return result
    }

    private mutating func primary() throws -> Double {
        if consume("(") {
            let result = try expression()
            try closeParenthesis()
            return result
        }
        skipSpaces()
        let start = index
        if index < characters.count, characters[index].isLetter {
            while index < characters.count, characters[index].isLetter { index += 1 }
            let name = String(characters[start..<index])
            if name == "pi" { return .pi }
            if name == "e" { return M_E }
            guard ["sqrt", "abs", "round", "floor", "ceil", "sin", "cos", "tan", "log", "ln"].contains(name) else {
                throw Issue.invalidExpression
            }
            guard consume("(") else { throw expectedMoreInput() }
            let value = try expression()
            try closeParenthesis()
            switch name {
            case "sqrt":
                guard value >= 0 else { throw Issue.domainError }
                return sqrt(value)
            case "abs": return abs(value)
            case "round": return value.rounded()
            case "floor": return floor(value)
            case "ceil": return ceil(value)
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "log", "ln":
                guard value > 0 else { throw Issue.domainError }
                return name == "log" ? log10(value) : log(value)
            default: throw Issue.invalidExpression
            }
        }
        while index < characters.count, characters[index].isNumber { index += 1 }
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber { index += 1 }
        }
        guard start != index, characters[start..<index].contains(where: \.isNumber) else {
            throw expectedMoreInput()
        }
        if index < characters.count, characters[index] == "e" {
            index += 1
            if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
            let exponentStart = index
            while index < characters.count, characters[index].isNumber { index += 1 }
            guard index > exponentStart else { throw expectedMoreInput() }
        }
        guard let number = Double(String(characters[start..<index])) else { throw Issue.invalidExpression }
        return try checked(number)
    }

    private func checked(_ value: Double) throws -> Double {
        guard !value.isNaN else { throw Issue.domainError }
        guard value.isFinite else { throw Issue.resultOutOfRange }
        return value
    }

    private mutating func closeParenthesis() throws {
        guard consume(")") else { throw expectedMoreInput() }
    }

    private mutating func expectedMoreInput() -> Issue {
        skipSpaces()
        return index == characters.count ? .incompleteExpression : .invalidExpression
    }

    private mutating func consume(_ character: Character) -> Bool {
        skipSpaces()
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    private mutating func skipSpaces() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }
}
