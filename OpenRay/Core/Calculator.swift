import Foundation

struct Calculation: Equatable, Sendable {
    var expression: String
    var result: String
    var detail: String
}

enum Calculator {
    static func evaluate(_ input: String) -> Calculation? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 512 else { return nil }
        if let conversion = convert(input) { return conversion }
        let normalized = input.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi")
        var parser = ExpressionParser(normalized)
        guard let value = try? parser.parse(), value.isFinite else { return nil }
        return Calculation(expression: input, result: format(value), detail: "Calculator · Return to copy")
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
    }

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

    private static func convert(_ input: String) -> Calculation? {
        let pattern = #"^(.+?)\s*([a-zA-Z°]+)\s+(?:in|to|as)\s+([a-zA-Z°]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
            let expressionRange = Range(match.range(at: 1), in: input),
            let sourceRange = Range(match.range(at: 2), in: input),
            let targetRange = Range(match.range(at: 3), in: input),
            let source = units[input[sourceRange].lowercased()],
            let target = units[input[targetRange].lowercased()],
            source.dimension == target.dimension
        else { return nil }
        var parser = ExpressionParser(String(input[expressionRange]))
        guard let number = try? parser.parse() else { return nil }
        let result = (number * source.scale + source.offset - target.offset) / target.scale
        guard result.isFinite else { return nil }
        return Calculation(
            expression: input, result: "\(format(result)) \(target.symbol)", detail: "Unit conversion · Return to copy")
    }
}

/// A bounded arithmetic grammar, never an expression evaluator or shell interpreter.
private struct ExpressionParser {
    private enum Failure: Error { case invalid }
    private let characters: [Character]
    private var index = 0
    private var depth = 0

    init(_ input: String) { characters = Array(input.lowercased()) }

    mutating func parse() throws -> Double {
        let result = try expression()
        skipSpaces()
        guard index == characters.count, result.isFinite else { throw Failure.invalid }
        return result
    }

    private mutating func expression() throws -> Double {
        var result = try product()
        while true {
            if consume("+") {
                result += try product()
            } else if consume("-") {
                result -= try product()
            } else {
                return result
            }
        }
    }

    private mutating func product() throws -> Double {
        var result = try unary()
        while true {
            if consume("*") {
                result *= try unary()
            } else if consume("/") {
                let divisor = try unary()
                guard divisor != 0 else { throw Failure.invalid }
                result /= divisor
            } else {
                return result
            }
        }
    }

    private mutating func unary() throws -> Double {
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw Failure.invalid }
        if consume("+") { return try unary() }
        if consume("-") { return try -unary() }
        var result = try primary()
        while consume("%") { result /= 100 }
        if consume("^") { result = pow(result, try unary()) }
        return result
    }

    private mutating func primary() throws -> Double {
        if consume("(") {
            let result = try expression()
            guard consume(")") else { throw Failure.invalid }
            return result
        }
        skipSpaces()
        let start = index
        if index < characters.count, characters[index].isLetter {
            while index < characters.count, characters[index].isLetter { index += 1 }
            let name = String(characters[start..<index])
            if name == "pi" { return .pi }
            if name == "e" { return M_E }
            guard consume("(") else { throw Failure.invalid }
            let value = try expression()
            guard consume(")") else { throw Failure.invalid }
            switch name {
            case "sqrt": return sqrt(value)
            case "abs": return abs(value)
            case "round": return value.rounded()
            case "floor": return floor(value)
            case "ceil": return ceil(value)
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "log": return log10(value)
            case "ln": return log(value)
            default: throw Failure.invalid
            }
        }
        while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
        if index < characters.count, characters[index] == "e" {
            index += 1
            if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
            while index < characters.count, characters[index].isNumber { index += 1 }
        }
        guard start != index, let number = Double(String(characters[start..<index])) else { throw Failure.invalid }
        return number
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
