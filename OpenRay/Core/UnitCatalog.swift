import Foundation

/// A kind of quantity. Units convert only within one dimension.
enum UnitDimension: String, Sendable, CaseIterable {
    case length, mass, time, storage, temperature, volume, area, speed, pressure, energy, power, angle, frequency
    case dataRate
}

/// One unit the calculator converts. Factors are exact definitions, so they're
/// more precise than Foundation's rounded `UnitConverterLinear` coefficients
/// (Foundation uses 1609.34 m per mile and 0.453592 kg per pound).
struct UnitDefinition: Hashable, Sendable {
    enum Family: Sendable {
        case general
        /// CSS and print sizes: px, pt, em, rem.
        case typography
        /// Kitchen measures: teaspoons to cups.
        case cooking
    }

    /// The display symbol. It's also an alias, so a swapped query parses again.
    var symbol: String
    var name: String
    var dimension: UnitDimension
    /// How many base units one of this unit is (meters, kilograms, seconds, bytes,
    /// kelvin, liters, square meters, m/s, pascals, joules, watts, radians, hertz, bit/s).
    var scale: Double
    var offset: Double = 0
    var family: Family = .general
    /// Scales with the root font size instead of a fixed factor.
    var isRelativeToFontSize = false

    func scale(pixelsPerEm: Double) -> Double {
        isRelativeToFontSize ? UnitCatalog.pixel * pixelsPerEm : scale
    }
}

enum UnitCatalog {
    static let inch = 0.0254
    static let pixel = inch / 96
    static let point = inch / 72

    /// Every unit, in definition order.
    static let all: [UnitDefinition] = definitions.map(\.unit)

    /// Units an alias names. Most aliases name one unit; "pt" names a point and a pint,
    /// and the other side of the conversion decides.
    static func units(named alias: String) -> [UnitDefinition] {
        index[normalizedAlias(alias)] ?? []
    }

    static func unit(symbol: String) -> UnitDefinition? {
        bySymbol[symbol]
    }

    /// The pair of units that share a dimension, or nil when either alias is unknown.
    /// Throws `.incompatibleUnits` when both are known but never share a dimension.
    static func resolve(source: String, target: String) throws -> (UnitDefinition, UnitDefinition)? {
        let sources = units(named: source)
        let targets = units(named: target)
        guard !sources.isEmpty, !targets.isEmpty else { return nil }
        for candidate in sources {
            if let match = targets.first(where: { $0.dimension == candidate.dimension }) {
                return (candidate, match)
            }
        }
        throw Calculator.Issue.incompatibleUnits
    }

    /// The longest known alias that ends `text`, starting after a digit, space or
    /// closing parenthesis, so "1e3km" and "10 sq ft" both split cleanly.
    static func trailingAlias(in text: String) -> (expression: String, alias: String)? {
        for length in stride(from: min(maxAliasLength, text.count), through: 1, by: -1) {
            let start = text.index(text.endIndex, offsetBy: -length)
            let candidate = text[start...].lowercased()
            guard index[normalizedAlias(candidate)] != nil, candidate.first?.isWhitespace == false else { continue }
            let expression = text[..<start]
            guard let previous = expression.last, previous.isNumber || previous.isWhitespace || previous == ")" || previous == "."
            else { continue }
            let trimmed = expression.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return (trimmed, candidate)
        }
        return nil
    }

    /// Units shown beside a conversion, in a familiar order.
    static func relatedSymbols(source: UnitDefinition, target: UnitDefinition) -> [String] {
        if source.family == .typography || target.family == .typography {
            return ["px", "pt", "rem", "em", "in", "mm"]
        }
        if source.family == .cooking || target.family == .cooking {
            return ["mL", "tbsp", "tsp", "cup", "fl oz"]
        }
        return relatedOrder[source.dimension] ?? []
    }

    static func normalizedAlias(_ alias: String) -> String {
        alias.lowercased()
            .replacingOccurrences(of: "²", with: "2")
            .replacingOccurrences(of: "³", with: "3")
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "μ", with: "µ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Table

    private static let relatedOrder: [UnitDimension: [String]] = [
        .length: ["ft", "m", "yd", "km", "mi", "cm", "in"],
        .mass: ["g", "kg", "lb", "oz"],
        .time: ["min", "h", "s", "days", "weeks"],
        .storage: ["MB", "GB", "MiB", "GiB", "KB", "TB"],
        .temperature: ["°C", "°F", "K"],
        .volume: ["mL", "L", "US gal"],
        .area: ["m²", "ft²", "km²", "ha", "acres", "mi²"],
        .speed: ["km/h", "mph", "m/s", "kn", "ft/s"],
        .pressure: ["kPa", "bar", "psi", "atm", "hPa"],
        .energy: ["kJ", "kcal", "kWh", "BTU", "J"],
        .power: ["W", "kW", "hp"],
        .angle: ["°", "rad", "grad", "turns"],
        .frequency: ["Hz", "kHz", "MHz", "GHz"],
        .dataRate: ["Mbps", "MB/s", "Gbps", "kbps"],
    ]

    private struct Definition {
        var unit: UnitDefinition
        var aliases: [String]
    }

    private static let definitions: [Definition] = {
        var result: [Definition] = []
        func add(
            _ symbol: String, _ name: String, _ dimension: UnitDimension, _ scale: Double, _ aliases: [String],
            offset: Double = 0, family: UnitDefinition.Family = .general, relative: Bool = false
        ) {
            result.append(
                Definition(
                    unit: UnitDefinition(
                        symbol: symbol, name: name, dimension: dimension, scale: scale, offset: offset, family: family,
                        isRelativeToFontSize: relative),
                    aliases: [symbol] + aliases))
        }

        // Length, in meters.
        add("m", "Meters", .length, 1, ["meter", "meters", "metre", "metres"])
        add("km", "Kilometers", .length, 1_000, ["kilometer", "kilometers", "kilometre", "kilometres"])
        add("cm", "Centimeters", .length, 0.01, ["centimeter", "centimeters", "centimetre", "centimetres"])
        add("mm", "Millimeters", .length, 0.001, ["millimeter", "millimeters", "millimetre", "millimetres"])
        add("dm", "Decimeters", .length, 0.1, ["decimeter", "decimeters"])
        add("µm", "Micrometers", .length, 1e-6, ["um", "micrometer", "micrometers", "micron", "microns"])
        add("nm", "Nanometers", .length, 1e-9, ["nanometer", "nanometers"])
        add("mi", "Miles", .length, 1_609.344, ["mile", "miles"])
        add("ft", "Feet", .length, 0.3048, ["foot", "feet", "′"])
        add("in", "Inches", .length, inch, ["inch", "inches", "″"])
        add("yd", "Yards", .length, 0.9144, ["yard", "yards"])
        add("nmi", "Nautical Miles", .length, 1_852, ["nautical mile", "nautical miles"])
        add("ly", "Light-years", .length, 9_460_730_472_580_800, ["light year", "light years", "light-year", "light-years"])
        add("au", "Astronomical Units", .length, 149_597_870_700, ["astronomical unit", "astronomical units"])
        add("px", "Pixels", .length, pixel, ["pixel", "pixels"], family: .typography)
        add("pt", "Points", .length, point, ["point", "points"], family: .typography)
        add("rem", "Root Ems", .length, pixel * 16, [], family: .typography, relative: true)
        add("em", "Ems", .length, pixel * 16, [], family: .typography, relative: true)

        // Mass, in kilograms.
        add("kg", "Kilograms", .mass, 1, ["kilogram", "kilograms", "kilo", "kilos"])
        add("g", "Grams", .mass, 0.001, ["gram", "grams"])
        add("mg", "Milligrams", .mass, 1e-6, ["milligram", "milligrams"])
        add("µg", "Micrograms", .mass, 1e-9, ["ug", "mcg", "microgram", "micrograms"])
        add("t", "Tonnes", .mass, 1_000, ["tonne", "tonnes", "metric ton", "metric tons"])
        add("lb", "Pounds", .mass, 0.45359237, ["lbs", "pound", "pounds"])
        add("oz", "Ounces", .mass, 0.028349523125, ["ounce", "ounces"])
        add("st", "Stone", .mass, 6.35029318, ["stone", "stones"])
        add("US ton", "US Tons", .mass, 907.18474, ["ton", "tons", "short ton", "short tons"])
        add("ct", "Carats", .mass, 0.0002, ["carat", "carats"])

        // Time, in seconds.
        add("s", "Seconds", .time, 1, ["sec", "secs", "second", "seconds"])
        add("ms", "Milliseconds", .time, 0.001, ["millisecond", "milliseconds"])
        add("µs", "Microseconds", .time, 1e-6, ["microsecond", "microseconds"])
        add("ns", "Nanoseconds", .time, 1e-9, ["nanosecond", "nanoseconds"])
        add("min", "Minutes", .time, 60, ["mins", "minute", "minutes"])
        add("h", "Hours", .time, 3_600, ["hr", "hrs", "hour", "hours"])
        add("days", "Days", .time, 86_400, ["d", "day"])
        add("weeks", "Weeks", .time, 604_800, ["week", "wk", "wks"])
        add("fortnights", "Fortnights", .time, 1_209_600, ["fortnight"])
        add("months", "Months", .time, 2_629_746, ["month", "mo"])
        add("years", "Years", .time, 31_556_952, ["year", "yr", "yrs"])
        add("decades", "Decades", .time, 315_569_520, ["decade"])
        add("centuries", "Centuries", .time, 3_155_695_200, ["century"])

        // Storage, in bytes.
        add("B", "Bytes", .storage, 1, ["byte", "bytes"])
        add("bit", "Bits", .storage, 0.125, ["bits"])
        add("nibble", "Nibbles", .storage, 0.5, ["nibbles"])
        add("KB", "Kilobytes", .storage, 1e3, ["kilobyte", "kilobytes"])
        add("MB", "Megabytes", .storage, 1e6, ["megabyte", "megabytes"])
        add("GB", "Gigabytes", .storage, 1e9, ["gigabyte", "gigabytes"])
        add("TB", "Terabytes", .storage, 1e12, ["terabyte", "terabytes"])
        add("PB", "Petabytes", .storage, 1e15, ["petabyte", "petabytes"])
        add("KiB", "Kibibytes", .storage, 1_024, ["kibibyte", "kibibytes"])
        add("MiB", "Mebibytes", .storage, 1_048_576, ["mebibyte", "mebibytes"])
        add("GiB", "Gibibytes", .storage, 1_073_741_824, ["gibibyte", "gibibytes"])
        add("TiB", "Tebibytes", .storage, 1_099_511_627_776, ["tebibyte", "tebibytes"])
        add("kbit", "Kilobits", .storage, 125, ["kilobit", "kilobits"])
        add("Mbit", "Megabits", .storage, 125_000, ["megabit", "megabits"])
        add("Gbit", "Gigabits", .storage, 125_000_000, ["gigabit", "gigabits"])

        // Temperature, in kelvin.
        add("°C", "Celsius", .temperature, 1, ["c", "celsius", "degc"], offset: 273.15)
        add("°F", "Fahrenheit", .temperature, 5.0 / 9, ["f", "fahrenheit", "degf"], offset: 255.3722222222222)
        add("K", "Kelvin", .temperature, 1, ["kelvin"])
        add("°R", "Rankine", .temperature, 5.0 / 9, ["rankine"])

        // Volume, in liters.
        add("L", "Liters", .volume, 1, ["l", "liter", "liters", "litre", "litres"])
        add("mL", "Milliliters", .volume, 0.001, ["milliliter", "milliliters", "millilitre", "millilitres"])
        add("cL", "Centiliters", .volume, 0.01, ["centiliter", "centiliters"])
        add("dL", "Deciliters", .volume, 0.1, ["deciliter", "deciliters"])
        add("m³", "Cubic Meters", .volume, 1_000, ["cubic meter", "cubic meters", "cubic metre", "cubic metres"])
        add("cm³", "Cubic Centimeters", .volume, 0.001, ["cc", "cubic centimeter", "cubic centimeters"])
        add("in³", "Cubic Inches", .volume, 0.016387064, ["cubic inch", "cubic inches", "cu in"])
        add("ft³", "Cubic Feet", .volume, 28.316846592, ["cubic foot", "cubic feet", "cu ft"])
        add("US gal", "US Gallons", .volume, 3.785411784, ["gal", "gallon", "gallons", "us gallon", "us gallons"])
        add("imp gal", "Imperial Gallons", .volume, 4.54609, ["uk gal", "imperial gallon", "imperial gallons"])
        add("qt", "US Quarts", .volume, 0.946352946, ["quart", "quarts"])
        add("US pt", "US Pints", .volume, 0.473176473, ["pt", "pint", "pints", "us pint", "us pints"])
        add("imp pt", "Imperial Pints", .volume, 0.56826125, ["uk pint", "uk pints", "imperial pint", "imperial pints"])
        add("cup", "US Cups", .volume, 0.2365882365, ["cups", "us cup", "us cups"], family: .cooking)
        add("fl oz", "US Fluid Ounces", .volume, 0.0295735295625, ["floz", "fluid ounce", "fluid ounces"], family: .cooking)
        add("tbsp", "Tablespoons", .volume, 0.01478676478125, ["tbs", "tablespoon", "tablespoons"], family: .cooking)
        add("tsp", "Teaspoons", .volume, 0.00492892159375, ["teaspoon", "teaspoons"], family: .cooking)

        // Area, in square meters.
        add("m²", "Square Meters", .area, 1, ["m2", "sq m", "sqm", "square meter", "square meters", "square metre", "square metres"])
        add("km²", "Square Kilometers", .area, 1e6, ["km2", "sq km", "square kilometer", "square kilometers"])
        add("cm²", "Square Centimeters", .area, 1e-4, ["cm2", "sq cm", "square centimeter", "square centimeters"])
        add("mm²", "Square Millimeters", .area, 1e-6, ["mm2", "sq mm", "square millimeter", "square millimeters"])
        add("ha", "Hectares", .area, 10_000, ["hectare", "hectares"])
        add("acres", "Acres", .area, 4_046.8564224, ["acre", "ac"])
        add("ft²", "Square Feet", .area, 0.09290304, ["ft2", "sq ft", "sqft", "square foot", "square feet"])
        add("in²", "Square Inches", .area, 0.00064516, ["in2", "sq in", "square inch", "square inches"])
        add("yd²", "Square Yards", .area, 0.83612736, ["yd2", "sq yd", "square yard", "square yards"])
        add("mi²", "Square Miles", .area, 2_589_988.110336, ["mi2", "sq mi", "square mile", "square miles"])

        // Speed, in meters per second.
        add("m/s", "Meters per Second", .speed, 1, ["mps", "meters per second", "metres per second"])
        add("km/h", "Kilometers per Hour", .speed, 1 / 3.6, ["kmh", "kph", "kmph", "kilometers per hour", "kilometres per hour"])
        add("mph", "Miles per Hour", .speed, 0.44704, ["mi/h", "miles per hour"])
        add("kn", "Knots", .speed, 1_852.0 / 3_600, ["kt", "kts", "knot", "knots"])
        add("ft/s", "Feet per Second", .speed, 0.3048, ["fps", "feet per second"])

        // Pressure, in pascals.
        add("Pa", "Pascals", .pressure, 1, ["pascal", "pascals"])
        add("hPa", "Hectopascals", .pressure, 100, ["hectopascal", "hectopascals"])
        add("kPa", "Kilopascals", .pressure, 1_000, ["kilopascal", "kilopascals"])
        add("MPa", "Megapascals", .pressure, 1e6, ["megapascal", "megapascals"])
        add("bar", "Bars", .pressure, 100_000, ["bars"])
        add("mbar", "Millibars", .pressure, 100, ["millibar", "millibars"])
        add("psi", "Pounds per Square Inch", .pressure, 6_894.757293168361, [])
        add("atm", "Atmospheres", .pressure, 101_325, ["atmosphere", "atmospheres"])
        add("mmHg", "Millimeters of Mercury", .pressure, 133.322387415, [])
        add("inHg", "Inches of Mercury", .pressure, 3_386.388640341, [])
        add("Torr", "Torr", .pressure, 101_325.0 / 760, [])

        // Energy, in joules.
        add("J", "Joules", .energy, 1, ["joule", "joules"])
        add("kJ", "Kilojoules", .energy, 1_000, ["kilojoule", "kilojoules"])
        add("MJ", "Megajoules", .energy, 1e6, ["megajoule", "megajoules"])
        add("cal", "Calories", .energy, 4.184, ["calorie", "calories"])
        add("kcal", "Kilocalories", .energy, 4_184, ["kilocalorie", "kilocalories"])
        add("Wh", "Watt-hours", .energy, 3_600, ["watt hour", "watt hours", "watt-hour", "watt-hours"])
        add("kWh", "Kilowatt-hours", .energy, 3.6e6, ["kilowatt hour", "kilowatt hours", "kilowatt-hour", "kilowatt-hours"])
        add("MWh", "Megawatt-hours", .energy, 3.6e9, [])
        add("eV", "Electronvolts", .energy, 1.602176634e-19, ["electronvolt", "electronvolts"])
        add("BTU", "British Thermal Units", .energy, 1_055.05585262, ["btus"])

        // Power, in watts.
        add("W", "Watts", .power, 1, ["watt", "watts"])
        add("kW", "Kilowatts", .power, 1_000, ["kilowatt", "kilowatts"])
        add("MW", "Megawatts", .power, 1e6, ["megawatt", "megawatts"])
        add("hp", "Horsepower", .power, 745.6998715822702, ["horsepower"])

        // Angle, in radians.
        add("°", "Degrees", .angle, .pi / 180, ["deg", "degs", "degree", "degrees"])
        add("rad", "Radians", .angle, 1, ["rads", "radian", "radians"])
        add("grad", "Gradians", .angle, .pi / 200, ["gon", "gradian", "gradians"])
        add("arcmin", "Arcminutes", .angle, .pi / 10_800, ["arcminute", "arcminutes"])
        add("arcsec", "Arcseconds", .angle, .pi / 648_000, ["arcsecond", "arcseconds"])
        add("turns", "Turns", .angle, 2 * .pi, ["turn", "rev", "revs", "revolution", "revolutions"])

        // Frequency, in hertz.
        add("Hz", "Hertz", .frequency, 1, ["hertz"])
        add("kHz", "Kilohertz", .frequency, 1_000, ["kilohertz"])
        add("MHz", "Megahertz", .frequency, 1e6, ["megahertz"])
        add("GHz", "Gigahertz", .frequency, 1e9, ["gigahertz"])
        add("rpm", "Revolutions per Minute", .frequency, 1.0 / 60, [])

        // Data rate, in bits per second.
        add("bps", "Bits per Second", .dataRate, 1, ["bit/s", "bits per second"])
        add("kbps", "Kilobits per Second", .dataRate, 1e3, ["kbit/s", "kilobits per second"])
        add("Mbps", "Megabits per Second", .dataRate, 1e6, ["mbit/s", "megabits per second"])
        add("Gbps", "Gigabits per Second", .dataRate, 1e9, ["gbit/s", "gigabits per second"])
        add("B/s", "Bytes per Second", .dataRate, 8, ["bytes per second"])
        add("KB/s", "Kilobytes per Second", .dataRate, 8e3, ["kilobytes per second"])
        add("MB/s", "Megabytes per Second", .dataRate, 8e6, ["megabytes per second"])
        add("GB/s", "Gigabytes per Second", .dataRate, 8e9, ["gigabytes per second"])
        add("MiB/s", "Mebibytes per Second", .dataRate, 8_388_608, [])
        return result
    }()

    private static let index: [String: [UnitDefinition]] = {
        var result: [String: [UnitDefinition]] = [:]
        for definition in definitions {
            for alias in Set(definition.aliases.map(normalizedAlias)) {
                result[alias, default: []].append(definition.unit)
            }
        }
        // "b" was always bytes here, and "ton" US tons; keep the first definition first.
        return result
    }()

    private static let bySymbol: [String: UnitDefinition] = Dictionary(
        definitions.map { ($0.unit.symbol, $0.unit) }, uniquingKeysWith: { first, _ in first })

    private static let maxAliasLength = index.keys.map(\.count).max() ?? 1
}

// MARK: - Music notes

/// Scientific pitch notation with A4 = 440 Hz, such as "c4 to hz" or "440 hz to note".
enum MusicNote {
    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let offsets: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]

    /// The MIDI number for a note such as "A4", "c#5" or "Bb3".
    static func midiNumber(of note: String) -> Int? {
        let characters = Array(note.lowercased().replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b"))
        guard let first = characters.first, let base = offsets[first] else { return nil }
        var index = 1
        var semitone = base
        if index < characters.count, characters[index] == "#" {
            semitone += 1
            index += 1
        } else if index < characters.count, characters[index] == "b", index + 1 < characters.count {
            semitone -= 1
            index += 1
        }
        guard let octave = Int(String(characters[index...])), (-1...9).contains(octave) else { return nil }
        return (octave + 1) * 12 + semitone
    }

    static func frequency(midi: Int) -> Double {
        440 * pow(2, Double(midi - 69) / 12)
    }

    /// The nearest note to a frequency, and how many cents sharp (+) or flat (−) it is.
    static func nearest(to frequency: Double) -> (name: String, cents: Int)? {
        guard frequency > 0, frequency.isFinite else { return nil }
        // Subtracting logarithms avoids the underflow of frequency / 440 for tiny values.
        let exact = 69 + 12 * (log2(frequency) - log2(440.0))
        let rounded = exact.rounded()
        guard rounded.isFinite, (0...127).contains(rounded) else { return nil }
        let midi = Int(rounded)
        let cents = Int(((exact - Double(midi)) * 100).rounded())
        return ("\(names[midi % 12])\(midi / 12 - 1)", cents)
    }
}
