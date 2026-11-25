import Foundation

struct Calculation: Equatable, Sendable {
    /// What a result is, so views and actions can label and treat it.
    enum Kind: String, Codable, Equatable, Sendable {
        case arithmetic, conversion, currency, date, duration, time, percentage, base, fraction
    }

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
    var kind: Kind = .arithmetic
    /// The query with source and target units swapped ("10 mi in km" for "10 km in mi"),
    /// for the Swap Units action. Nil when the result isn't a two-sided conversion.
    var swapQuery: String? = nil
    /// Captions under the input and the result, such as "London (GMT)", when the
    /// result isn't a unit conversion.
    var inputLabel: String? = nil
    var resultLabel: String? = nil
    /// The instant a date or time result names.
    var date: Date? = nil

    /// The number as shown. A conversion shows six significant digits and copies all of them.
    var shownValue: String { conversion?.target.value ?? value }

    init(
        expression: String, result: String, detail: String, value: String? = nil, conversion: Conversion? = nil,
        kind: Kind? = nil, swapQuery: String? = nil, inputLabel: String? = nil, resultLabel: String? = nil,
        date: Date? = nil
    ) {
        self.expression = expression
        self.result = result
        self.detail = detail
        self.value = value ?? result
        self.conversion = conversion
        self.kind = kind ?? (conversion == nil ? .arithmetic : .conversion)
        self.swapQuery = swapQuery
        self.inputLabel = inputLabel
        self.resultLabel = resultLabel
        self.date = date
    }
}

/// Everything a calculation depends on besides its input, so tests can fix the clock,
/// calendar, time zone and rates.
struct CalculatorContext: Sendable {
    var now: Date
    /// Its time zone is the local one; its locale decides the weekend for workdays.
    var calendar: Calendar
    /// Formats dates and times. Numbers always use a fixed, ungrouped format.
    var locale: Locale
    /// Reference rates for currency conversion. Nil until the owner turns rates on.
    var currencyRates: CurrencyRateTable?
    /// CSS pixels per em and rem.
    var pixelsPerEm: Double

    init(
        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
        currencyRates: CurrencyRateTable? = nil, pixelsPerEm: Double = 16
    ) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.currencyRates = currencyRates
        self.pixelsPerEm = pixelsPerEm
    }

    static var live: CalculatorContext { CalculatorContext() }

    var timeZone: TimeZone { calendar.timeZone }
}

enum Calculator {
    enum Issue: Error, Equatable, Sendable {
        case incompleteExpression
        case divisionByZero
        case domainError
        case unsupportedCurrencyConversion
        case unknownCurrency
        case unsupportedConversion
        case incompatibleUnits
        case invalidExpression
        case resultOutOfRange
        case expressionTooComplex
        case needsWholeNumber
        case invalidDate

        var title: String {
            switch self {
            case .incompleteExpression: "Finish the expression"
            case .divisionByZero: "Can't divide by zero"
            case .domainError: "There's no real-number result"
            case .unsupportedCurrencyConversion: "Currency conversion isn't supported"
            case .unknownCurrency: "There's no rate for that currency"
            case .unsupportedConversion: "That unit isn't supported"
            case .incompatibleUnits: "These units don't match"
            case .invalidExpression: "Check the expression"
            case .resultOutOfRange: "The result is too large"
            case .expressionTooComplex: "Simplify the expression"
            case .needsWholeNumber: "Use a whole number"
            case .invalidDate: "That date doesn't exist"
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
            case .unknownCurrency:
                "Daily reference rates cover about 30 major currencies, such as USD, EUR, GBP and JPY."
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
            case .needsWholeNumber:
                "Number bases and factorials work with whole numbers, such as 255 in hex or 5!."
            case .invalidDate:
                "Check the day and month, such as 31 Mar or 2027-02-28."
            }
        }

        /// Issues specific enough to show while searching Everything.
        var isWorthShowingInSearch: Bool {
            switch self {
            case .divisionByZero, .domainError, .unsupportedCurrencyConversion, .unknownCurrency, .incompatibleUnits,
                .resultOutOfRange, .unsupportedConversion, .needsWholeNumber, .invalidDate:
                true
            default: false
            }
        }
    }

    /// An issue to show in place of a result, only when the input clearly is math.
    static func searchIssue(for input: String, context: CalculatorContext = .live) -> Issue? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isNumber || first == "(" || first == "-" || first == "√",
            trimmed.count >= 3, let issue = issue(for: trimmed, context: context), issue.isWorthShowingInSearch
        else { return nil }
        if issue == .unsupportedConversion {
            // Prose such as "2 days to go" has the same shape. Only an unknown unit
            // converted into a known one, as in "1 parsec in m", is clearly a conversion.
            guard let tokens = conversionTokens(in: normalized(trimmed)), let target = tokens.target,
                !UnitCatalog.units(named: target).isEmpty, UnitCatalog.units(named: tokens.source).isEmpty
            else { return nil }
        }
        return issue
    }

    static func issue(for input: String, context: CalculatorContext = .live) -> Issue? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try calculate(input, context: context)
            return nil
        } catch let issue as Issue {
            return issue
        } catch {
            return .invalidExpression
        }
    }

    static func evaluate(_ input: String, context: CalculatorContext = .live) -> Calculation? {
        try? calculate(input, context: context)
    }

    /// The calculation that Swap Units shows, or nil when the result has nothing to swap.
    static func swapped(_ calculation: Calculation, context: CalculatorContext = .live) -> Calculation? {
        calculation.swapQuery.flatMap { evaluate($0, context: context) }
    }

    private static func calculate(_ input: String, context: CalculatorContext) throws -> Calculation {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw Issue.incompleteExpression }
        guard input.count <= 512 else { throw Issue.expressionTooComplex }
        let normalized = Self.normalized(input)
        let phrases: [(String, CalculatorContext) throws -> Calculation?] = [
            NumberBases.evaluate, Fractions.evaluate, PercentPhrases.evaluate, musicNote,
            TimeZoneMath.evaluate, DateMath.evaluate,
        ]
        for phrase in phrases {
            if var calculation = try phrase(normalized, context) {
                calculation.expression = input
                return calculation
            }
        }
        if var conversion = try convert(normalized, context: context) {
            conversion.expression = input
            return conversion
        }
        let value = try parse(normalized)
        return Calculation(expression: input, result: format(value), detail: "Calculator · Return to copy")
    }

    static func normalized(_ input: String) -> String {
        input.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Evaluates a bounded arithmetic expression. Mixed numbers such as "1 1/2" count as one value.
    static func parse(_ expression: String) throws -> Double {
        var parser = ExpressionParser(mixedNumbersGrouped(expression))
        return try parser.parse()
    }

    /// "1 1/2" reads as one and a half wherever two numbers would otherwise sit side by side.
    private static func mixedNumbersGrouped(_ input: String) -> String {
        guard input.contains("/"), input.contains(" ") else { return input }
        return mixedNumber.regex.stringByReplacingMatches(
            in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "($1+$2/$3)")
    }

    private static let mixedNumber = CalculatorPattern(#"(?<![\d.)])(\d+)\s+(\d+)\s*/\s*(\d+)(?![\d.(])"#)

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

    /// A fixed number of decimals, ungrouped, for money.
    static func format(_ number: Double, fractionDigits: Int) -> String {
        let number = number == 0 ? 0 : number
        return number.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(fractionDigits)))
    }

    // MARK: - Conversions

    /// The parts of "<expression> <unit> in|to|as <unit>". Unit names are lowercased.
    /// Only explains failures; `convert` splits multi-word units itself.
    private struct ConversionTokens {
        var expression: String
        var source: String
        var target: String?
    }

    private static func conversionTokens(in input: String) -> ConversionTokens? {
        guard let groups = conversionShape.groups(in: input), let expression = groups[1], let source = groups[2] else {
            return nil
        }
        return ConversionTokens(expression: expression, source: source.lowercased(), target: groups[3]?.lowercased())
    }

    private static let conversionShape = CalculatorPattern(
        #"^(.+?)\s*([\p{L}°\p{Sc}]+)\s+(?:in|to|as)(?:\s+([\p{L}°\p{Sc}]+))?$"#)
    private static let connector = CalculatorPattern(#"\s+(?:into|in|to|as)(?=\s|$)"#)

    /// The ways to read "<left> in|to|as|into <right>", latest connector first.
    static func conversionSplits(of input: String) -> [(left: String, right: String)] {
        connector.regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed().compactMap { match in
            guard let range = Range(match.range, in: input) else { return nil }
            let left = input[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = input[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return left.isEmpty ? nil : (left, right)
        }
    }

    private static func convert(_ input: String, context: CalculatorContext) throws -> Calculation? {
        var incompatible = false
        for split in conversionSplits(of: input) where !split.right.isEmpty {
            guard let (expression, alias) = UnitCatalog.trailingAlias(in: split.left) else { continue }
            let units: (UnitDefinition, UnitDefinition)?
            do {
                units = try UnitCatalog.resolve(source: alias, target: split.right)
            } catch {
                incompatible = true
                continue
            }
            guard let (source, target) = units else { continue }
            let number = try parse(expression)
            return try unitConversion(
                number, expression: expression, from: source, to: target, sourceAlias: alias, targetAlias: split.right,
                context: context)
        }
        if let currency = try CurrencyConversion.evaluate(input, context: context) { return currency }
        if incompatible { throw Issue.incompatibleUnits }
        return try explainConversionFailure(input)
    }

    /// Reports why a single-word conversion failed, or nil when the input isn't shaped like one.
    private static func explainConversionFailure(_ input: String) throws -> Calculation? {
        guard let tokens = conversionTokens(in: input) else { return nil }
        _ = try parse(tokens.expression)
        guard let targetName = tokens.target else { throw Issue.incompleteExpression }
        if CurrencyCatalog.isCurrencyWord(tokens.source) || CurrencyCatalog.isCurrencyWord(targetName) {
            throw Issue.unsupportedCurrencyConversion
        }
        if try UnitCatalog.resolve(source: tokens.source, target: targetName) == nil {
            throw Issue.unsupportedConversion
        }
        throw Issue.incompatibleUnits
    }

    private static func unitConversion(
        _ number: Double, expression: String, from source: UnitDefinition, to target: UnitDefinition,
        sourceAlias: String, targetAlias: String, context: CalculatorContext
    ) throws -> Calculation {
        let sourceScale = source.scale(pixelsPerEm: context.pixelsPerEm)
        let targetScale = target.scale(pixelsPerEm: context.pixelsPerEm)
        let result = (number * sourceScale + source.offset - target.offset) / targetScale
        guard result.isFinite else { throw Issue.resultOutOfRange }
        let base = number * sourceScale + source.offset
        let related = UnitCatalog.relatedSymbols(source: source, target: target)
            .filter { $0 != source.symbol && $0 != target.symbol }
            .compactMap { symbol -> Calculation.Quantity? in
                guard let unit = UnitCatalog.unit(symbol: symbol) else { return nil }
                let value = (base - unit.offset) / unit.scale(pixelsPerEm: context.pixelsPerEm)
                guard value.isFinite else { return nil }
                return .init(
                    value: displayFormat(value), symbol: unit.symbol, name: unit.name, copyValue: format(value))
            }
            .prefix(4)
        return Calculation(
            expression: expression, result: "\(conversionFormat(result)) \(target.symbol)",
            detail: "Unit conversion · Return to copy", value: format(result),
            conversion: .init(
                source: .init(value: format(number), symbol: source.symbol, name: source.name),
                target: .init(
                    value: conversionFormat(result), symbol: target.symbol, name: target.name, copyValue: format(result)),
                related: Array(related)),
            kind: .conversion, swapQuery: "\(expression) \(target.symbol) in \(source.symbol)")
    }

    /// "a4 to hz" and "440 hz to note".
    private static func musicNote(_ input: String, context: CalculatorContext) throws -> Calculation? {
        let lowered = input.lowercased()
        if let groups = noteToFrequency.groups(in: lowered), let note = groups[1],
            let midi = MusicNote.midiNumber(of: note)
        {
            let frequency = MusicNote.frequency(midi: midi)
            return Calculation(
                expression: input, result: "\(conversionFormat(frequency)) Hz", detail: "Music note · Return to copy",
                value: format(frequency), kind: .conversion, inputLabel: "Note", resultLabel: "Hertz")
        }
        if let groups = frequencyToNote.groups(in: lowered), let expression = groups[1] {
            var hertz = try parse(expression)
            if groups[2] == "khz" { hertz *= 1_000 }
            guard let nearest = MusicNote.nearest(to: hertz) else { throw Issue.resultOutOfRange }
            let cents = nearest.cents == 0 ? "" : nearest.cents > 0 ? " +\(nearest.cents)¢" : " −\(-nearest.cents)¢"
            return Calculation(
                expression: input, result: nearest.name + cents, detail: "Music note · Return to copy",
                value: nearest.name, kind: .conversion, inputLabel: "Hertz", resultLabel: "Note")
        }
        return nil
    }

    private static let noteToFrequency = CalculatorPattern(#"^([a-g](?:#|♯|b|♭)?-?\d)\s+(?:in|to|as)\s+(?:hz|hertz|frequency)$"#)
    private static let frequencyToNote = CalculatorPattern(#"^(.+?)\s*(hz|hertz|khz)\s+(?:in|to|as)\s+(?:a\s+)?(?:note|pitch)$"#)
}

/// A case-insensitive, whole-input regular expression. `NSRegularExpression` is
/// immutable and documented as thread-safe.
struct CalculatorPattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid calculator pattern \(pattern): \(error)")
        }
    }

    /// Capture groups of a match of the whole input, with group 0 as the whole match.
    func groups(in input: String) -> [String?]? {
        guard let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
            match.range.location == 0, match.range.length == (input as NSString).length
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: input).map { String(input[$0]) }
        }
    }
}

/// A bounded arithmetic grammar, never an expression evaluator or shell interpreter.
private struct ExpressionParser {
    private typealias Issue = Calculator.Issue
    private let characters: [Character]
    private var index = 0
    private var depth = 0
    /// Whether the last unary term ended in `%` on its own, as in "50 + 20%".
    private var unaryEndedInPercent = false

    private static let functions: Set<String> = [
        "sqrt", "cbrt", "abs", "round", "floor", "ceil", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh",
        "tanh", "log", "log2", "ln", "exp",
    ]

    init(_ input: String) { characters = Array(input.lowercased()) }

    mutating func parse() throws -> Double {
        let result = try expression()
        skipSpaces()
        guard index == characters.count else { throw Issue.invalidExpression }
        return try checked(result)
    }

    /// Adding or subtracting a bare percentage scales the left side: 50 + 20% is 60.
    private mutating func expression() throws -> Double {
        var result = try product().value
        while true {
            if consume("+") {
                let term = try product()
                result = try checked(term.isPercent ? result + result * term.value : result + term.value)
            } else if consume("-") {
                let term = try product()
                result = try checked(term.isPercent ? result - result * term.value : result - term.value)
            } else {
                return result
            }
        }
    }

    private mutating func product() throws -> (value: Double, isPercent: Bool) {
        var result = try unary()
        var isPercent = unaryEndedInPercent
        while true {
            if consume("*") {
                result = try checked(result * unary())
            } else if consume("/") {
                let divisor = try unary()
                guard divisor != 0 else { throw Issue.divisionByZero }
                result = try checked(result / divisor)
            } else if consumeWord("mod") {
                let divisor = try unary()
                guard divisor != 0 else { throw Issue.divisionByZero }
                result = try checked(fmod(result, divisor))
            } else {
                return (result, isPercent)
            }
            isPercent = false
        }
    }

    private mutating func unary() throws -> Double {
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw Issue.expressionTooComplex }
        if consume("+") { return try unary() }
        if consume("-") { return try -unary() }
        if consume("√") {
            let value = try unary()
            guard value >= 0 else { throw Issue.domainError }
            return sqrt(value)
        }
        var result = try primary()
        var endedInPercent = false
        while true {
            if consume("%") {
                result /= 100
                endedInPercent = true
            } else if consume("!") {
                result = try factorial(result)
                endedInPercent = false
            } else {
                break
            }
        }
        if consume("^") {
            let exponent = try unary()
            guard result != 0 || exponent >= 0 else { throw Issue.divisionByZero }
            result = try checked(pow(result, exponent))
            endedInPercent = false
        }
        unaryEndedInPercent = endedInPercent
        return result
    }

    private func factorial(_ value: Double) throws -> Double {
        guard value >= 0, value == value.rounded() else { throw Issue.needsWholeNumber }
        guard value <= 170 else { throw Issue.resultOutOfRange }
        return (1...max(1, Int(value))).reduce(1.0) { $0 * Double($1) }
    }

    private mutating func primary() throws -> Double {
        if consume("(") {
            let result = try expression()
            try closeParenthesis()
            return result
        }
        skipSpaces()
        let start = index
        if let based = try basedLiteral() { return based }
        if index < characters.count, characters[index].isLetter {
            while index < characters.count, characters[index].isLetter || characters[index].isNumber && index > start {
                index += 1
            }
            let name = String(characters[start..<index])
            if name == "pi" { return .pi }
            if name == "e" { return M_E }
            guard Self.functions.contains(name) else { throw Issue.invalidExpression }
            guard consume("(") else { throw expectedMoreInput() }
            let value = try expression()
            try closeParenthesis()
            return try apply(name, to: value)
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

    /// 0x, 0b and 0o integer literals.
    private mutating func basedLiteral() throws -> Double? {
        guard index + 2 < characters.count, characters[index] == "0" else { return nil }
        let radix: Int
        switch characters[index + 1] {
        case "x": radix = 16
        case "b": radix = 2
        case "o": radix = 8
        default: return nil
        }
        var end = index + 2
        while end < characters.count, characters[end].isHexDigit, Int(String(characters[end]), radix: radix) != nil {
            end += 1
        }
        guard end > index + 2 else { return nil }
        guard let value = UInt64(String(characters[(index + 2)..<end]), radix: radix) else {
            throw Issue.resultOutOfRange
        }
        index = end
        return Double(value)
    }

    private func apply(_ name: String, to value: Double) throws -> Double {
        switch name {
        case "sqrt":
            guard value >= 0 else { throw Issue.domainError }
            return sqrt(value)
        case "cbrt": return cbrt(value)
        case "abs": return abs(value)
        case "round": return value.rounded()
        case "floor": return floor(value)
        case "ceil": return ceil(value)
        case "sin": return sin(value)
        case "cos": return cos(value)
        case "tan": return tan(value)
        case "asin", "acos":
            guard (-1...1).contains(value) else { throw Issue.domainError }
            return name == "asin" ? asin(value) : acos(value)
        case "atan": return atan(value)
        case "sinh": return sinh(value)
        case "cosh": return cosh(value)
        case "tanh": return tanh(value)
        case "exp": return try checked(exp(value))
        case "log", "ln", "log2":
            guard value > 0 else { throw Issue.domainError }
            return name == "log" ? log10(value) : name == "ln" ? log(value) : log2(value)
        default: throw Issue.invalidExpression
        }
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

    /// A word operator such as "mod", which must stand alone.
    private mutating func consumeWord(_ word: String) -> Bool {
        skipSpaces()
        let letters = Array(word)
        guard index + letters.count <= characters.count, Array(characters[index..<(index + letters.count)]) == letters
        else { return false }
        let end = index + letters.count
        guard end == characters.count || !characters[end].isLetter else { return false }
        index = end
        return true
    }

    private mutating func skipSpaces() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }
}
