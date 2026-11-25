import Foundation

/// A place or zone name resolved to a time zone, with the label OpenRay shows for it.
struct ZoneMatch: Equatable, Sendable {
    var timeZone: TimeZone
    var label: String
}

/// Cities, IATA airport codes, countries and abbreviations that name a time zone.
/// Any city in the system's time zone database ("berlin", "sao paulo") also works.
enum TimeZoneTable {
    static func zone(named name: String) -> ZoneMatch? {
        let key = normalized(name)
        guard !key.isEmpty, key.count <= 40 else { return nil }
        if let entry = curated[key], let zone = TimeZone(identifier: entry.identifier) {
            return ZoneMatch(timeZone: zone, label: entry.label)
        }
        if let offset = fixedOffset(key) { return offset }
        if let identifier = databaseCities[key], let zone = TimeZone(identifier: identifier) {
            return ZoneMatch(timeZone: zone, label: cityLabel(identifier))
        }
        return nil
    }

    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "utc+5:30", "gmt-3", "utc". Only a name with no offset means plain UTC; an
    /// impossible offset ("utc+99") names no zone at all.
    private static func fixedOffset(_ key: String) -> ZoneMatch? {
        guard let groups = offsetPattern.groups(in: key), let prefix = groups[1] else { return nil }
        guard let sign = groups[2], let hoursText = groups[3] else {
            return TimeZone(identifier: "UTC").map { ZoneMatch(timeZone: $0, label: prefix.uppercased()) }
        }
        guard let hours = Int(hoursText), hours <= 14 else { return nil }
        let minutes = groups[4].flatMap { Int($0) } ?? 0
        guard minutes < 60 else { return nil }
        let seconds = (hours * 3_600 + minutes * 60) * (sign == "-" ? -1 : 1)
        guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
        let label = "\(prefix.uppercased())\(sign)\(hours)" + (minutes == 0 ? "" : String(format: ":%02d", minutes))
        return ZoneMatch(timeZone: zone, label: label)
    }

    private static let offsetPattern = CalculatorPattern(#"^(utc|gmt|z)(?:\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?)?$"#)

    private static func cityLabel(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// Every zone identifier, and its city part: "new york" for America/New_York.
    private static let databaseCities: [String: String] = {
        var result: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers where identifier.contains("/") {
            result[normalized(identifier)] = identifier
            let city = normalized(cityLabel(identifier))
            if result[city] == nil { result[city] = identifier }
        }
        return result
    }()

    private struct Entry {
        var identifier: String
        var label: String
    }

    /// Aliases the zone database doesn't spell out. Abbreviations name the region's zone,
    /// so "PST" follows daylight saving the way people use it.
    private static let curated: [String: Entry] = {
        var table: [String: Entry] = [:]
        func add(_ identifier: String, _ label: String, _ aliases: [String]) {
            for alias in aliases + [label] {
                let key = normalized(alias)
                if table[key] == nil { table[key] = Entry(identifier: identifier, label: label) }
            }
        }
        // Abbreviations first, so they win over airport codes such as IST (Istanbul).
        add("America/Los_Angeles", "Pacific Time", ["pst", "pdt", "pt", "pacific", "pacific time"])
        add("America/Denver", "Mountain Time", ["mst", "mdt", "mt", "mountain", "mountain time"])
        add("America/Chicago", "Central Time", ["cst", "cdt", "ct", "central", "central time"])
        add("America/New_York", "Eastern Time", ["est", "edt", "et", "eastern", "eastern time"])
        add("America/Anchorage", "Alaska Time", ["akst", "akdt"])
        add("Pacific/Honolulu", "Hawaii Time", ["hst", "hawaii"])
        add("America/Halifax", "Atlantic Time", ["ast", "adt", "atlantic"])
        add("America/St_Johns", "Newfoundland Time", ["nst", "ndt"])
        add("Europe/London", "UK Time", ["bst", "uk time", "british time"])
        add("Europe/Dublin", "Irish Time", ["irish time"])
        add("Europe/Lisbon", "Western European Time", ["wet", "west"])
        add("Europe/Berlin", "Central European Time", ["cet", "cest", "mez", "mesz"])
        add("Europe/Athens", "Eastern European Time", ["eet", "eest"])
        add("Europe/Moscow", "Moscow Time", ["msk"])
        add("Asia/Dubai", "Gulf Time", ["gst"])
        add("Asia/Karachi", "Pakistan Time", ["pkt"])
        add("Asia/Kolkata", "India Time", ["ist", "india time"])
        add("Asia/Bangkok", "Indochina Time", ["ict"])
        add("Asia/Jakarta", "Western Indonesia Time", ["wib"])
        add("Asia/Singapore", "Singapore Time", ["sgt"])
        add("Asia/Hong_Kong", "Hong Kong Time", ["hkt"])
        add("Asia/Shanghai", "China Time", ["china time", "beijing time"])
        add("Asia/Tokyo", "Japan Time", ["jst"])
        add("Asia/Seoul", "Korea Time", ["kst"])
        add("Australia/Sydney", "Australian Eastern Time", ["aest", "aedt"])
        add("Australia/Adelaide", "Australian Central Time", ["acst", "acdt"])
        add("Australia/Perth", "Australian Western Time", ["awst"])
        add("Pacific/Auckland", "New Zealand Time", ["nzst", "nzdt"])
        add("Africa/Johannesburg", "South Africa Time", ["sast"])
        add("Africa/Lagos", "West Africa Time", ["wat"])
        add("Africa/Nairobi", "East Africa Time", ["eat"])
        add("America/Sao_Paulo", "Brasília Time", ["brt"])
        add("America/Argentina/Buenos_Aires", "Argentina Time", ["art"])

        // Cities, nicknames and airports.
        add("Europe/London", "London", ["ldn", "lon", "lhr", "lgw", "stn", "ltn", "lcy", "uk", "united kingdom", "england", "britain", "great britain"])
        add("Europe/London", "Manchester", ["man", "manchester"])
        add("Europe/London", "Edinburgh", ["edi", "scotland", "glasgow", "gla"])
        add("Europe/Dublin", "Dublin", ["dub", "ireland"])
        add("Europe/Paris", "Paris", ["cdg", "ory", "france"])
        add("Europe/Paris", "Nice", ["nce"])
        add("Europe/Paris", "Lyon", ["lys"])
        add("Europe/Berlin", "Berlin", ["ber", "germany"])
        add("Europe/Berlin", "Munich", ["muc", "munchen", "münchen"])
        add("Europe/Berlin", "Frankfurt", ["fra"])
        add("Europe/Berlin", "Hamburg", ["ham"])
        add("Europe/Berlin", "Cologne", ["cgn", "koln", "köln"])
        add("Europe/Amsterdam", "Amsterdam", ["ams", "netherlands", "holland"])
        add("Europe/Brussels", "Brussels", ["bru", "belgium"])
        add("Europe/Zurich", "Zurich", ["zrh", "zürich", "switzerland", "geneva", "gva", "basel"])
        add("Europe/Vienna", "Vienna", ["vie", "austria"])
        add("Europe/Madrid", "Madrid", ["mad", "spain"])
        add("Europe/Madrid", "Barcelona", ["bcn"])
        add("Europe/Lisbon", "Lisbon", ["lis", "portugal"])
        add("Europe/Rome", "Rome", ["fco", "italy"])
        add("Europe/Rome", "Milan", ["mxp", "lin", "milano"])
        add("Europe/Copenhagen", "Copenhagen", ["cph", "denmark"])
        add("Europe/Stockholm", "Stockholm", ["arn", "sweden"])
        add("Europe/Oslo", "Oslo", ["osl", "norway"])
        add("Europe/Helsinki", "Helsinki", ["hel", "finland"])
        add("Europe/Warsaw", "Warsaw", ["waw", "poland"])
        add("Europe/Prague", "Prague", ["prg", "czechia", "czech republic"])
        add("Europe/Budapest", "Budapest", ["bud", "hungary"])
        add("Europe/Athens", "Athens", ["ath", "greece"])
        add("Europe/Istanbul", "Istanbul", ["saw", "turkey", "turkiye"])
        add("Europe/Kyiv", "Kyiv", ["kiev", "kbp", "ukraine"])
        add("Europe/Moscow", "Moscow", ["svo", "dme", "russia"])
        add("Atlantic/Reykjavik", "Reykjavik", ["kef", "iceland"])
        add("Asia/Dubai", "Dubai", ["dxb", "uae", "abu dhabi", "auh"])
        add("Asia/Qatar", "Doha", ["doh", "qatar"])
        add("Asia/Riyadh", "Riyadh", ["ruh", "saudi arabia", "jeddah", "jed"])
        add("Asia/Jerusalem", "Tel Aviv", ["tlv", "israel", "jerusalem"])
        add("Africa/Cairo", "Cairo", ["cai", "egypt"])
        add("Asia/Tehran", "Tehran", ["ika", "iran"])
        add("Asia/Karachi", "Karachi", ["khi", "pakistan"])
        add("Asia/Kolkata", "Mumbai", ["bom", "bombay"])
        add("Asia/Kolkata", "Delhi", ["del", "new delhi"])
        add("Asia/Kolkata", "Bengaluru", ["blr", "bangalore"])
        add("Asia/Kolkata", "Chennai", ["maa"])
        add("Asia/Kolkata", "Hyderabad", ["hyd"])
        add("Asia/Kolkata", "India", ["india"])
        add("Asia/Dhaka", "Dhaka", ["dac", "bangladesh"])
        add("Asia/Kathmandu", "Kathmandu", ["ktm", "nepal"])
        add("Asia/Bangkok", "Bangkok", ["bkk", "thailand"])
        add("Asia/Ho_Chi_Minh", "Ho Chi Minh City", ["sgn", "saigon", "vietnam", "hanoi", "han"])
        add("Asia/Jakarta", "Jakarta", ["cgk", "indonesia"])
        add("Asia/Singapore", "Singapore", ["sin"])
        add("Asia/Kuala_Lumpur", "Kuala Lumpur", ["kul", "malaysia"])
        add("Asia/Manila", "Manila", ["mnl", "philippines"])
        add("Asia/Hong_Kong", "Hong Kong", ["hkg", "hk"])
        add("Asia/Shanghai", "Shanghai", ["pvg", "sha"])
        add("Asia/Shanghai", "Beijing", ["pek", "pkx", "peking", "china"])
        add("Asia/Shanghai", "Shenzhen", ["szx", "guangzhou", "can"])
        add("Asia/Taipei", "Taipei", ["tpe", "taiwan"])
        add("Asia/Tokyo", "Tokyo", ["tyo", "nrt", "hnd", "japan"])
        add("Asia/Tokyo", "Osaka", ["kix", "itm", "kyoto"])
        add("Asia/Seoul", "Seoul", ["icn", "gmp", "south korea", "korea"])
        add("Australia/Sydney", "Sydney", ["syd", "australia"])
        add("Australia/Melbourne", "Melbourne", ["mel"])
        add("Australia/Brisbane", "Brisbane", ["bne"])
        add("Australia/Perth", "Perth", ["per"])
        add("Australia/Adelaide", "Adelaide", ["adl"])
        add("Pacific/Auckland", "Auckland", ["akl", "new zealand", "nz", "wellington", "wlg"])
        add("Africa/Johannesburg", "Johannesburg", ["jnb", "south africa", "cape town", "cpt"])
        add("Africa/Lagos", "Lagos", ["los", "nigeria"])
        add("Africa/Nairobi", "Nairobi", ["nbo", "kenya"])
        add("Africa/Casablanca", "Casablanca", ["cmn", "morocco"])
        add("America/New_York", "New York", ["nyc", "ny", "jfk", "lga", "ewr", "new york city", "manhattan", "brooklyn"])
        add("America/New_York", "Boston", ["bos"])
        add("America/New_York", "Washington, D.C.", ["dc", "washington", "washington dc", "dca", "iad"])
        add("America/New_York", "Philadelphia", ["phl", "philly"])
        add("America/New_York", "Miami", ["mia"])
        add("America/New_York", "Atlanta", ["atl"])
        add("America/Toronto", "Toronto", ["yyz", "yto"])
        add("America/Toronto", "Montreal", ["yul", "montréal"])
        add("America/Chicago", "Chicago", ["chi", "ord", "mdw"])
        add("America/Chicago", "Dallas", ["dfw", "dal"])
        add("America/Chicago", "Houston", ["iah", "hou"])
        add("America/Chicago", "Austin", ["aus"])
        add("America/Mexico_City", "Mexico City", ["mex", "cdmx", "mexico"])
        add("America/Denver", "Denver", ["den"])
        add("America/Phoenix", "Phoenix", ["phx", "arizona"])
        add("America/Los_Angeles", "Los Angeles", ["la", "lax"])
        add("America/Los_Angeles", "San Francisco", ["sf", "sfo", "san fran", "bay area", "silicon valley", "oakland", "oak"])
        add("America/Los_Angeles", "San Jose", ["sjc"])
        add("America/Los_Angeles", "Seattle", ["sea"])
        add("America/Los_Angeles", "Portland", ["pdx"])
        add("America/Los_Angeles", "Las Vegas", ["las", "vegas"])
        add("America/Los_Angeles", "San Diego", ["san"])
        add("America/Vancouver", "Vancouver", ["yvr"])
        add("America/Anchorage", "Anchorage", ["anc", "alaska"])
        add("Pacific/Honolulu", "Honolulu", ["hnl"])
        add("America/Sao_Paulo", "São Paulo", ["gru", "sao paulo", "brazil", "rio", "rio de janeiro", "gig"])
        add("America/Argentina/Buenos_Aires", "Buenos Aires", ["eze", "argentina"])
        add("America/Santiago", "Santiago", ["scl", "chile"])
        add("America/Bogota", "Bogotá", ["bog", "bogota", "colombia"])
        add("America/Lima", "Lima", ["lim", "peru"])
        return table
    }()
}

/// "5pm ldn in sf", "time in tokyo", "10am PST to CET", "tokyo time", "time diff paris".
enum TimeZoneMath {
    static func evaluate(_ input: String, context: CalculatorContext) throws -> Calculation? {
        let text = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard text.count <= 80 else { return nil }
        if let current = currentTime(text, context: context) { return current }
        if let difference = difference(text, context: context) { return difference }
        return conversion(text, context: context)
    }

    /// "time in tokyo", "what time is it in tokyo", "tokyo time", "now in tokyo".
    private static func currentTime(_ text: String, context: CalculatorContext) -> Calculation? {
        guard let groups = currentPattern.groups(in: text), let place = groups[1] ?? groups[2] ?? groups[3],
            let zone = TimeZoneTable.zone(named: place)
        else { return nil }
        let now = context.now
        let time = CalendarFormat.time(now, context: context, timeZone: zone.timeZone)
        let day = CalendarFormat.dayAndMonth(now, context: context, timeZone: zone.timeZone)
        let offset = relation(of: zone.timeZone, to: context.timeZone, named: "local time", at: now)
        return Calculation(
            expression: "", result: time, detail: "\(zone.label) · \(day) · \(offset) · Return to copy", kind: .time,
            resultLabel: "\(zone.label) · \(day)", date: now)
    }

    private static let currentPattern = CalculatorPattern(
        #"^(?:(?:what(?:'s| is)? (?:the )?(?:current |local )?|current |local )?time(?: is it)?(?: now)? (?:in|at) (.+)|(.+?) time|now in (.+))$"#)

    /// "time diff paris", "time difference between tokyo and london".
    private static func difference(_ text: String, context: CalculatorContext) -> Calculation? {
        let first: ZoneMatch
        let second: ZoneMatch
        if let groups = differencePairPattern.groups(in: text), let a = groups[1], let b = groups[2],
            let left = TimeZoneTable.zone(named: a), let right = TimeZoneTable.zone(named: b)
        {
            first = left
            second = right
        } else if let groups = differencePattern.groups(in: text), let place = groups[1],
            let zone = TimeZoneTable.zone(named: place)
        {
            first = zone
            second = ZoneMatch(timeZone: context.timeZone, label: "local time")
        } else {
            return nil
        }
        let description = relation(of: first.timeZone, to: second.timeZone, named: second.label, at: context.now)
        let hours = Double(first.timeZone.secondsFromGMT(for: context.now) - second.timeZone.secondsFromGMT(for: context.now)) / 3_600
        let sign = hours > 0 ? "+" : ""
        return Calculation(
            expression: "", result: "\(sign)\(Calculator.format(hours)) h",
            detail: "\(first.label) is \(description) · Return to copy",
            value: Calculator.format(hours), kind: .time, inputLabel: second.label, resultLabel: first.label)
    }

    private static let differencePairPattern = CalculatorPattern(
        #"^(?:time )?diff(?:erence)? (?:between )?(.+?) (?:and|vs|to) (.+)$"#)
    private static let differencePattern = CalculatorPattern(#"^(?:time )?diff(?:erence)? (?:in |with |to )?(.+)$"#)

    /// "5pm ldn in sf", "17:00 utc to tokyo", "5pm in tokyo" (from local), "3pm est" (to local).
    private static func conversion(_ text: String, context: CalculatorContext) -> Calculation? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.first != "now", let time = TimeOfDay.parse(tokens, at: 0), time.length < tokens.count else {
            return nil
        }
        let length = time.length
        let rest = tokens[length...].joined(separator: " ")
        var pair: (source: ZoneMatch, sourceAlias: String?, target: ZoneMatch, targetAlias: String?)?
        for split in Calculator.conversionSplits(of: rest) where !split.right.isEmpty {
            if let target = TimeZoneTable.zone(named: split.right), let source = TimeZoneTable.zone(named: split.left) {
                pair = (source, split.left, target, split.right)
                break
            }
        }
        if pair == nil, rest.hasPrefix("in ") || rest.hasPrefix("to "),
            let target = TimeZoneTable.zone(named: String(rest.dropFirst(3)))
        {
            pair = (localZone(context), nil, target, String(rest.dropFirst(3)))
        }
        if pair == nil, let source = TimeZoneTable.zone(named: rest) {
            pair = (source, rest, localZone(context), nil)
        }
        guard let pair else { return nil }

        var sourceCalendar = context.calendar
        sourceCalendar.timeZone = pair.source.timeZone
        let sourceDay = sourceCalendar.startOfDay(for: context.now)
        guard let instant = time.time.date(on: sourceDay, calendar: sourceCalendar) else { return nil }
        let shown = CalendarFormat.time(instant, context: context, timeZone: pair.target.timeZone)
        let sourceShown = CalendarFormat.time(instant, context: context, timeZone: pair.source.timeZone)
        let targetDay = CalendarFormat.dayAndMonth(instant, context: context, timeZone: pair.target.timeZone)
        let sourceAbbreviation = abbreviation(pair.source.timeZone, at: instant)
        let targetAbbreviation = abbreviation(pair.target.timeZone, at: instant)
        let offset = relation(of: pair.target.timeZone, to: pair.source.timeZone, named: pair.source.label, at: instant)
        let timeText = tokens[..<length].joined(separator: " ")
        let swap: String? =
            pair.targetAlias.map { target in
                "\(timeText) \(target) in \(pair.sourceAlias ?? localAlias(pair.source))"
            }
        return Calculation(
            expression: "", result: shown,
            detail: "\(pair.target.label) · \(targetDay) · \(offset) · Return to copy",
            kind: .time, swapQuery: pair.targetAlias == nil ? nil : swap,
            inputLabel: "\(sourceShown) · \(pair.source.label) (\(sourceAbbreviation))",
            resultLabel: "\(pair.target.label) (\(targetAbbreviation)) · \(targetDay)", date: instant)
    }

    /// "PST", "CET", "GMT+9", with "GMT+0" shortened to "GMT".
    private static func abbreviation(_ zone: TimeZone, at date: Date) -> String {
        let text = zone.abbreviation(for: date) ?? ""
        return text == "GMT+0" || text == "UTC+0" ? String(text.prefix(3)) : text
    }

    private static func localZone(_ context: CalculatorContext) -> ZoneMatch {
        ZoneMatch(timeZone: context.timeZone, label: "Local")
    }

    /// An alias that resolves back to a zone, for swapped queries.
    private static func localAlias(_ zone: ZoneMatch) -> String {
        zone.timeZone.identifier
    }

    /// "9 hours ahead of London", "5 hours 30 minutes behind local time", "the same time as Paris".
    static func relation(of zone: TimeZone, to other: TimeZone, named name: String, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date) - other.secondsFromGMT(for: date)
        guard seconds != 0 else { return "the same time as \(name)" }
        let hours = abs(seconds) / 3_600
        let minutes = abs(seconds) % 3_600 / 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) minutes") }
        return parts.joined(separator: " ") + (seconds > 0 ? " ahead of \(name)" : " behind \(name)")
    }
}
