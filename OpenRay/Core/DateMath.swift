import Foundation

/// Dates and durations: "days until 31 Mar", "monday in 3 weeks", "3 weeks from today",
/// week numbers, unix time and workdays. Every answer comes from the context's clock
/// and calendar, never the wall clock.
enum DateMath {
    static func evaluate(_ input: String, context: CalculatorContext) throws -> Calculation? {
        let tokens = tokenize(input)
        guard !tokens.isEmpty, tokens.count <= 16,
            tokens.indices.contains(where: { index in
                vocabulary.contains(tokens[index]) || isoDate.groups(in: tokens[index]) != nil
                    || TimeOfDay.parse(tokens, at: index) != nil
            })
        else { return nil }
        var parser = DateParser(tokens: tokens, context: context)
        return try parser.query()
    }

    /// Lowercased words, with "+" as its own word except inside ISO 8601 offsets.
    static func tokenize(_ input: String) -> [String] {
        input.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "?", with: " ")
            .split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
                let word = String(word)
                guard word.contains("+"), isoDate.groups(in: word) == nil else { return [word] }
                return word.replacingOccurrences(of: "+", with: " + ").split(separator: " ").map(String.init)
            }
    }

    /// Weekdays from the start of `start`'s day up to, not including, `end`'s day.
    static func workdays(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: min(start, end))
        let last = calendar.startOfDay(for: max(start, end))
        guard let span = calendar.dateComponents([.day], from: first, to: last).day, span > 0 else { return 0 }
        let weekdaysPerWeek = (0..<7).filter { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map { !calendar.isDateInWeekend($0) } ?? false
        }.count
        var count = span / 7 * weekdaysPerWeek
        for offset in 0..<(span % 7) {
            if let day = calendar.date(byAdding: .day, value: span / 7 * 7 + offset, to: first),
                !calendar.isDateInWeekend(day)
            {
                count += 1
            }
        }
        return start <= end ? count : -count
    }

    /// The most working days a phrase may add: about 40 years.
    static let maximumWorkdays = 10_000

    /// Adds working days, skipping the calendar's weekend. Any seven days in a row hold
    /// the same number of workdays, so whole weeks jump at once and at most a week is
    /// walked day by day; this runs on every keystroke. Nil beyond `maximumWorkdays`.
    static func adding(workdays: Int, to date: Date, calendar: Calendar) -> Date? {
        guard workdays.magnitude <= UInt(maximumWorkdays) else { return nil }
        let step = workdays < 0 ? -1 : 1
        var remaining = Int(workdays.magnitude)
        let perWeek = (1...7).filter { offset in
            calendar.date(byAdding: .day, value: offset, to: date).map { !calendar.isDateInWeekend($0) } ?? false
        }.count
        guard perWeek > 0 else { return nil }
        var result = date
        let weeks = max(0, (remaining - 1) / perWeek)
        if weeks > 0 {
            guard let jumped = calendar.date(byAdding: .day, value: step * weeks * 7, to: result) else { return nil }
            result = jumped
            remaining -= weeks * perWeek
        }
        var steps = 0
        while remaining > 0 {
            guard steps < 14, let next = calendar.date(byAdding: .day, value: step, to: result) else { return nil }
            result = next
            steps += 1
            if !calendar.isDateInWeekend(result) { remaining -= 1 }
        }
        return result
    }

    /// Easter Sunday in the Gregorian calendar (the anonymous algorithm).
    static func easter(year: Int) -> DateComponents {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return DateComponents(year: year, month: month, day: day)
    }

    /// Year, month, day; then optional hour, minute, second, fraction and offset.
    static let isoDate = CalculatorPattern(
        #"^(\d{4})-(\d{2})-(\d{2})(?:t(\d{2}):(\d{2})(?::(\d{2})(\.\d{1,9})?)?(z|[+-]\d{2}(?::?\d{2})?)?)?$"#)

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    /// Gregorian weekday numbers: Sunday is 1.
    static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7,
    ]

    private static let vocabulary: Set<String> = Set(months.keys).union(weekdays.keys).union([
        "today", "tomorrow", "yesterday", "now", "time", "tonight", "unix", "timestamp", "epoch", "week", "weeks", "days",
        "day", "months", "month", "years", "year", "hours", "minutes", "seconds", "workdays", "weekdays", "until",
        "till", "since", "ago", "from", "between", "next", "last", "christmas", "xmas", "easter", "halloween",
        "valentine's", "valentines", "new", "workday", "business", "working", "fortnight", "fortnights", "noon",
        "midnight", "date",
    ])
}

/// A time of day such as "5pm", "5:30 pm", "17:00", "noon" or "midnight".
struct TimeOfDay: Equatable, Sendable {
    var hour: Int
    var minute: Int

    /// The time at `index`, and how many tokens it used. Bare numbers aren't times.
    static func parse(_ tokens: [String], at index: Int) -> (time: TimeOfDay, length: Int)? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        if token == "noon" || token == "midday" { return (TimeOfDay(hour: 12, minute: 0), 1) }
        if token == "midnight" { return (TimeOfDay(hour: 0, minute: 0), 1) }
        guard let groups = clock.groups(in: token), let hourText = groups[1], let hour = Int(hourText) else {
            return nil
        }
        let minute = groups[2].flatMap { Int($0) } ?? 0
        var suffix = groups[3]
        var length = 1
        if suffix == nil, index + 1 < tokens.count, ["am", "pm", "a.m.", "p.m."].contains(tokens[index + 1]) {
            suffix = tokens[index + 1]
            length = 2
        }
        guard suffix != nil || groups[2] != nil, (0...59).contains(minute) else { return nil }
        if let suffix {
            guard (1...12).contains(hour) else { return nil }
            let afternoon = suffix.hasPrefix("p")
            return (TimeOfDay(hour: hour % 12 + (afternoon ? 12 : 0), minute: minute), length)
        }
        guard (0...23).contains(hour) else { return nil }
        return (TimeOfDay(hour: hour, minute: minute), length)
    }

    func date(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    private static let clock = CalculatorPattern(#"^(\d{1,2})(?::(\d{2}))?(am|pm|a\.m\.|p\.m\.)?$"#)
}

/// Formatting shared by date and time zone results. Narrow and thin spaces from
/// ICU become plain spaces, so copied answers paste cleanly anywhere.
enum CalendarFormat {
    static func date(_ date: Date, context: CalculatorContext, timeZone: TimeZone? = nil) -> String {
        clean(date.formatted(style(context, timeZone, date: .complete, time: .omitted)))
    }

    static func dateTime(_ date: Date, context: CalculatorContext, timeZone: TimeZone? = nil, seconds: Bool = false)
        -> String
    {
        let day = self.date(date, context: context, timeZone: timeZone)
        let time = clean(date.formatted(style(context, timeZone, date: .omitted, time: seconds ? .standard : .shortened)))
        return "\(day), \(time)"
    }

    static func time(_ date: Date, context: CalculatorContext, timeZone: TimeZone? = nil) -> String {
        clean(date.formatted(style(context, timeZone, date: .omitted, time: .shortened)))
    }

    /// "Thursday, November 26" without the year.
    static func dayAndMonth(_ date: Date, context: CalculatorContext, timeZone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle(locale: context.locale, calendar: context.calendar, timeZone: timeZone ?? context.timeZone)
        style = style.weekday(.wide).month(.wide).day()
        return clean(date.formatted(style))
    }

    static func shortDate(_ date: Date, context: CalculatorContext) -> String {
        var style = Date.FormatStyle(locale: context.locale, calendar: context.calendar, timeZone: context.timeZone)
        style = style.month(.abbreviated).day().year()
        return clean(date.formatted(style))
    }

    static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
    }

    private static func style(
        _ context: CalculatorContext, _ timeZone: TimeZone?, date: Date.FormatStyle.DateStyle,
        time: Date.FormatStyle.TimeStyle
    ) -> Date.FormatStyle {
        Date.FormatStyle(
            date: date, time: time, locale: context.locale, calendar: context.calendar,
            timeZone: timeZone ?? context.timeZone)
    }

    /// "1 day", "3 weeks", "2.5 hours".
    static func count(_ value: Double, _ singular: String, _ plural: String) -> String {
        let rounded = (value * 100).rounded() / 100
        return "\(Calculator.format(rounded)) \(abs(rounded) == 1 ? singular : plural)"
    }

    /// "4 months, 6 days", or "3 hours, 20 minutes, 5 seconds" for timed spans.
    static func breakdown(from start: Date, to end: Date, calendar: Calendar, includeTime: Bool) -> String {
        let (first, last) = start <= end ? (start, end) : (end, start)
        let components = calendar.dateComponents(
            includeTime ? [.year, .month, .day, .hour, .minute, .second] : [.year, .month, .day], from: first, to: last)
        let parts: [(Int?, String, String)] = [
            (components.year, "year", "years"), (components.month, "month", "months"), (components.day, "day", "days"),
            (components.hour, "hour", "hours"), (components.minute, "minute", "minutes"),
            (components.second, "second", "seconds"),
        ]
        let text = parts.compactMap { value, singular, plural -> String? in
            guard let value, value != 0 else { return nil }
            return "\(value) \(value == 1 ? singular : plural)"
        }.joined(separator: ", ")
        return text.isEmpty ? (includeTime ? "0 seconds" : "0 days") : text
    }

    /// "today", "tomorrow", "in 19 days", "3 days ago".
    static func relative(_ date: Date, context: CalculatorContext) -> String {
        let calendar = context.calendar
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: context.now), to: calendar.startOfDay(for: date)
            ).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let days where days > 0: return "in \(days) days"
        default: return "\(-days) days ago"
        }
    }
}

// MARK: - Parser

private struct DateParser {
    typealias Issue = Calculator.Issue

    enum YearHint { case future, past, current }

    struct ParsedDate {
        var date: Date
        var hasTime = false
        var hasExplicitYear = true
        var isTimeOnly = false
    }

    struct ParsedDuration {
        var parts: [(Calendar.Component, Int)] = []
        var seconds: Double = 0
        var workdays = 0
        var hasTime: Bool { seconds != 0 || parts.contains { [.hour, .minute, .second].contains($0.0) } }
    }

    enum CountUnit {
        case seconds, minutes, hours, days, weeks, months, years, workdays, span
    }

    let tokens: [String]
    let context: CalculatorContext
    /// Month and weekday names, ISO dates and four-digit years are Gregorian whatever
    /// calendar the Mac uses. Answers are still formatted with the context's calendar.
    let calendar: Calendar
    var index = 0
    var sawInvalidDate = false
    /// A duration or timestamp too large to compute. Checked like `sawInvalidDate`, so
    /// only a complete phrase reports it and trailing prose never does.
    var sawOutOfRange = false

    init(tokens: [String], context: CalculatorContext) {
        self.tokens = tokens
        self.context = context
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = context.calendar.timeZone
        if let locale = context.calendar.locale { gregorian.locale = locale }
        gregorian.firstWeekday = context.calendar.firstWeekday
        gregorian.minimumDaysInFirstWeek = context.calendar.minimumDaysInFirstWeek
        calendar = gregorian
    }
    var today: Date { calendar.startOfDay(for: context.now) }
    var atEnd: Bool { index == tokens.count }

    func peek(_ offset: Int = 0) -> String? {
        index + offset < tokens.count ? tokens[index + offset] : nil
    }

    mutating func accept(_ words: String...) -> Bool {
        guard index + words.count <= tokens.count, Array(tokens[index..<(index + words.count)]) == words else {
            return false
        }
        index += words.count
        return true
    }

    mutating func acceptAny(_ words: Set<String>) -> String? {
        guard let token = peek(), words.contains(token) else { return nil }
        index += 1
        return token
    }

    /// Runs `body`, rewinding when it doesn't match.
    mutating func attempt<T>(_ body: (inout DateParser) throws -> T?) rethrows -> T? {
        let start = index
        let invalid = sawInvalidDate
        let outOfRange = sawOutOfRange
        if let value = try body(&self) { return value }
        index = start
        sawInvalidDate = invalid
        sawOutOfRange = outOfRange
        return nil
    }

    // MARK: Query forms

    mutating func query() throws -> Calculation? {
        let forms: [(inout DateParser) throws -> Calculation?] = [
            { try $0.unixNow() }, { try $0.unixToDate() }, { try $0.dateToUnix() }, { try $0.weekNumber() },
            { try $0.weekRange() }, { try $0.count() }, { try $0.weekdayIn() }, { try $0.relativeDuration() },
            { try $0.dateOffset() }, { try $0.difference() }, { try $0.bareDate() },
        ]
        for form in forms {
            index = 0
            sawInvalidDate = false
            sawOutOfRange = false
            if let result = try form(&self), atEnd {
                if sawInvalidDate { throw Issue.invalidDate }
                if sawOutOfRange { throw Issue.resultOutOfRange }
                return result
            }
        }
        return nil
    }

    mutating func unixNow() throws -> Calculation? {
        let phrases: [[String]] = [
            ["unix", "time"], ["unix", "timestamp"], ["timestamp"], ["epoch", "time"],
            ["current", "timestamp"], ["current", "unix", "time"], ["unix", "time", "now"], ["timestamp", "now"],
        ]
        guard phrases.contains(tokens) else { return nil }
        index = tokens.count
        let seconds = Int(context.now.timeIntervalSince1970.rounded(.down))
        return Calculation(
            expression: "", result: "\(seconds)", detail: "Unix time · Return to copy", kind: .date,
            resultLabel: "Unix time", date: context.now)
    }

    /// "unix 0", "unix -86400", "1700000000 to date", "1700000000000 ms to date". A marker
    /// (unix, timestamp, epoch, to date) accepts any signed number of seconds; "ms" marks
    /// milliseconds, and a value too large for seconds but in range for milliseconds is read
    /// as milliseconds.
    mutating func unixToDate() throws -> Calculation? {
        let milliseconds: Set<String> = ["ms", "millis", "milliseconds"]
        var number: String?
        var isMilliseconds = false
        if acceptAny(["unix", "timestamp", "epoch"]) != nil || accept("from", "unix") {
            _ = acceptAny(["time", "timestamp"])
            isMilliseconds = acceptAny(milliseconds) != nil
            number = acceptNumber()
            isMilliseconds = acceptAny(milliseconds) != nil || isMilliseconds
        } else if let token = acceptNumber() {
            isMilliseconds = acceptAny(milliseconds) != nil
            let suffix =
                accept("unix", "time") || accept("unix", "timestamp") || accept("unix") || accept("timestamp")
                || accept("to", "date", "time") || accept("to", "date") || accept("as", "date") || accept("in", "date")
            guard suffix else { return nil }
            number = token
        }
        guard let number, atEnd, let value = Double(number) else { return nil }
        var seconds = isMilliseconds ? value / 1_000 : value
        if !isMilliseconds, abs(seconds) > Self.maximumUnixSeconds, abs(value) <= Self.maximumUnixSeconds * 1_000 {
            seconds = value / 1_000
        }
        guard abs(seconds) <= Self.maximumUnixSeconds else { throw Issue.resultOutOfRange }
        let date = Date(timeIntervalSince1970: seconds)
        return Calculation(
            expression: "", result: CalendarFormat.dateTime(date, context: context, seconds: true),
            detail: "\(CalendarFormat.iso8601(date)) · Return to copy", kind: .date, inputLabel: "Unix time",
            date: date)
    }

    mutating func dateToUnix() throws -> Calculation? {
        var parsed: ParsedDate?
        if accept("unix", "time", "of") || accept("unix", "time", "for") || accept("timestamp", "of")
            || accept("timestamp", "for") || accept("unix", "timestamp", "of")
        {
            parsed = try date(hint: .current, allowBare: true)
        } else {
            parsed = try date(hint: .current, allowBare: true)
            guard parsed != nil, acceptAny(["to", "in", "as"]) != nil, acceptAny(["unix", "timestamp", "epoch"]) != nil
            else { return nil }
            _ = accept("time")
        }
        guard let parsed, atEnd else { return nil }
        let seconds = Calculator.format(parsed.date.timeIntervalSince1970)
        return Calculation(
            expression: "", result: seconds, detail: "Unix time · Return to copy", kind: .date,
            resultLabel: "Unix time", date: parsed.date)
    }

    mutating func weekNumber() throws -> Calculation? {
        let target: Date
        if accept("week", "number") || accept("week", "no") || accept("week", "num") || accept("current", "week")
            || accept("what", "week", "is", "it") || accept("which", "week", "is", "it")
        {
            if atEnd || accept("today") || accept("now") {
                target = today
            } else if acceptAny(["of", "for", "on"]) != nil, let parsed = try date(hint: .current, allowBare: true) {
                target = parsed.date
            } else {
                return nil
            }
        } else if accept("week", "of"), let parsed = try date(hint: .current, allowBare: true) {
            target = parsed.date
        } else {
            return nil
        }
        let iso = isoCalendar
        let week = iso.component(.weekOfYear, from: target)
        let year = iso.component(.yearForWeekOfYear, from: target)
        guard let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)),
            let sunday = iso.date(byAdding: .day, value: 6, to: monday)
        else { return nil }
        let range = "\(CalendarFormat.shortDate(monday, context: context)) – \(CalendarFormat.shortDate(sunday, context: context))"
        return Calculation(
            expression: "", result: "Week \(week)", detail: "\(range) · Return to copy", value: "\(week)", kind: .date,
            resultLabel: "ISO week of \(year)", date: monday)
    }

    mutating func weekRange() throws -> Calculation? {
        guard acceptAny(["week", "wk"]) != nil, let token = peek(), let week = Int(token), (1...53).contains(week) else {
            return nil
        }
        index += 1
        _ = acceptAny(["of", "in"])
        let iso = isoCalendar
        var year = iso.component(.yearForWeekOfYear, from: today)
        if let token = peek(), token.count == 4, let explicit = Int(token) {
            index += 1
            year = explicit
        }
        guard atEnd,
            let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)),
            iso.component(.weekOfYear, from: monday) == week,
            let sunday = iso.date(byAdding: .day, value: 6, to: monday)
        else { return nil }
        let range = "\(CalendarFormat.shortDate(monday, context: context)) – \(CalendarFormat.shortDate(sunday, context: context))"
        return Calculation(
            expression: "", result: range, detail: "ISO week \(week) of \(year) · Return to copy", kind: .date,
            resultLabel: "Week \(week)", date: monday)
    }

    /// "days until 31 mar", "workdays since monday", "days between 1 jan and 31 mar",
    /// "days left in this month", "how long until christmas".
    mutating func count() throws -> Calculation? {
        let asked = accept("how", "many")
        let howLong = !asked && (accept("how", "long") || accept("time"))
        let unit: CountUnit
        if howLong {
            unit = .span
        } else if let parsed = countUnit() {
            unit = parsed
        } else {
            return nil
        }
        _ = accept("are", "there") || accept("is", "it")
        let start: Date
        let end: Date
        var includeTime = false
        var named: Date
        if acceptAny(["until", "till", "til", "to", "before"]) != nil {
            guard let target = try date(hint: .future, allowBare: true) else { return nil }
            start = target.hasTime ? context.now : today
            end = target.date
            named = end
            includeTime = target.hasTime
        } else if acceptAny(["since", "after"]) != nil {
            guard let origin = try date(hint: .past, allowBare: true) else { return nil }
            start = origin.date
            end = origin.hasTime ? context.now : today
            named = start
            includeTime = origin.hasTime
        } else if acceptAny(["between", "from"]) != nil {
            guard let first = try date(hint: .current, allowBare: true) else { return nil }
            named = first.date
            if atEnd, tokens.contains("from") {
                start = first.date
                end = first.hasTime ? context.now : today
            } else {
                guard acceptAny(["and", "to", "until", "till", "-"]) != nil,
                    var second = try date(hint: .current, allowBare: true)
                else { return nil }
                if !second.hasExplicitYear, second.date < first.date,
                    let later = calendar.date(byAdding: .year, value: 1, to: second.date)
                {
                    second.date = later
                }
                start = first.date
                end = second.date
                named = end
                includeTime = first.hasTime || second.hasTime
            }
        } else if acceptAny(["left", "remaining"]) != nil {
            _ = accept("in")
            _ = acceptAny(["this", "the"])
            guard let period = acceptAny(["month", "year", "week"]) else { return nil }
            let component: Calendar.Component = period == "month" ? .month : period == "year" ? .year : .weekOfYear
            guard let interval = (period == "week" ? isoCalendar : calendar).dateInterval(of: component, for: today)
            else { return nil }
            start = today
            end = interval.end
            named = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        } else {
            return nil
        }
        guard atEnd else { return nil }
        return countResult(unit, from: start, to: end, named: named, includeTime: includeTime)
    }

    mutating func countUnit() -> CountUnit? {
        if accept("business", "days") || accept("working", "days") || accept("work", "days")
            || acceptAny(["workdays", "weekdays", "workday", "weekday"]) != nil
        {
            return .workdays
        }
        switch acceptAny([
            "days", "day", "weeks", "week", "months", "month", "years", "year", "hours", "hour", "minutes", "mins",
            "seconds", "secs", "fortnights",
        ]) {
        case "days", "day": return .days
        case "weeks", "week": return .weeks
        case "months", "month": return .months
        case "years", "year": return .years
        case "hours", "hour": return .hours
        case "minutes", "mins": return .minutes
        case "seconds", "secs": return .seconds
        default: return nil
        }
    }

    func countResult(_ unit: CountUnit, from start: Date, to end: Date, named: Date, includeTime: Bool) -> Calculation {
        let days = Double(calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0)
        let interval = end.timeIntervalSince(start)
        let shown: String
        let value: Double
        switch unit {
        case .days:
            value = includeTime ? interval / 86_400 : days
            shown = CalendarFormat.count(value, "day", "days")
        case .weeks:
            value = (includeTime ? interval / 86_400 : days) / 7
            shown = CalendarFormat.count(value, "week", "weeks")
        case .months:
            let parts = calendar.dateComponents([.month, .day], from: start, to: end)
            value = Double(parts.month ?? 0) + Double(parts.day ?? 0) / 30.436875
            shown = CalendarFormat.count(value, "month", "months")
        case .years:
            value = days / 365.2425
            shown = CalendarFormat.count(value, "year", "years")
        case .hours:
            value = interval / 3_600
            shown = CalendarFormat.count(value, "hour", "hours")
        case .minutes:
            value = interval / 60
            shown = CalendarFormat.count(value, "minute", "minutes")
        case .seconds:
            value = interval
            shown = CalendarFormat.count(value, "second", "seconds")
        case .workdays:
            value = Double(DateMath.workdays(from: start, to: end, calendar: calendar))
            shown = CalendarFormat.count(value, "workday", "workdays")
        case .span:
            let text = CalendarFormat.breakdown(from: start, to: end, calendar: calendar, includeTime: includeTime || days == 0)
            return Calculation(
                expression: "", result: text, detail: "\(describe(named, hasTime: includeTime)) · Return to copy",
                kind: .duration, date: named)
        }
        let rounded = (value * 100).rounded() / 100
        let breakdown = CalendarFormat.breakdown(from: start, to: end, calendar: calendar, includeTime: includeTime)
        return Calculation(
            expression: "", result: shown,
            detail: "\(describe(named, hasTime: includeTime)) · \(breakdown) · Return to copy",
            value: Calculator.format(rounded), kind: .duration, date: named)
    }

    /// "monday in 3 weeks": that weekday in the week three weeks from today.
    mutating func weekdayIn() throws -> Calculation? {
        guard let name = peek(), let weekday = DateMath.weekdays[name] else { return nil }
        index += 1
        guard accept("in"), let duration = duration(), atEnd,
            let shifted = apply(duration, to: today, sign: 1)
        else { return nil }
        let monday = calendar.date(byAdding: .day, value: -mondayOffset(of: shifted), to: shifted) ?? shifted
        guard let date = calendar.date(byAdding: .day, value: (weekday + 5) % 7, to: monday) else { return nil }
        return dateResult(ParsedDate(date: date))
    }

    /// "3 weeks from today", "2 days ago", "in 3 days", "time in 4 hours", "10 workdays from now".
    mutating func relativeDuration() throws -> Calculation? {
        let wantsTime = accept("time", "in")
        if wantsTime || accept("in") {
            guard let duration = duration(), atEnd,
                let date = apply(duration, to: wantsTime || duration.hasTime ? context.now : today, sign: 1)
            else { return nil }
            return dateResult(ParsedDate(date: date, hasTime: wantsTime || duration.hasTime), timeOnly: wantsTime)
        }
        guard let duration = duration() else { return nil }
        if accept("ago") || accept("before", "now") || accept("before", "today") {
            guard atEnd, let date = apply(duration, to: duration.hasTime ? context.now : today, sign: -1) else {
                return nil
            }
            return dateResult(ParsedDate(date: date, hasTime: duration.hasTime))
        }
        if accept("from", "now") || accept("from", "today") || accept("later") || accept("hence") {
            guard atEnd, let date = apply(duration, to: duration.hasTime ? context.now : today, sign: 1) else {
                return nil
            }
            return dateResult(ParsedDate(date: date, hasTime: duration.hasTime))
        }
        guard let direction = acceptAny(["from", "after", "before"]),
            let anchor = try date(hint: .current, allowBare: true), atEnd,
            let date = apply(duration, to: anchor.date, sign: direction == "before" ? -1 : 1)
        else { return nil }
        return dateResult(ParsedDate(date: date, hasTime: anchor.hasTime || duration.hasTime))
    }

    /// "today + 3 days", "31 mar - 2 weeks".
    mutating func dateOffset() throws -> Calculation? {
        guard let anchor = try date(hint: .current, allowBare: true),
            let sign = acceptAny(["+", "plus", "-", "minus"]), let duration = duration(), atEnd,
            let date = apply(duration, to: anchor.date, sign: sign == "+" || sign == "plus" ? 1 : -1)
        else { return nil }
        return dateResult(ParsedDate(date: date, hasTime: anchor.hasTime || duration.hasTime))
    }

    /// "31 mar - 1 jan", "from 1 jan to 31 mar", "between 1 jan and 31 mar", "10pm to 2am".
    mutating func difference() throws -> Calculation? {
        let between = accept("between")
        let from = !between && accept("from")
        guard var first = try date(hint: .current, allowBare: from || between, allowTimeOnly: true, allowUnix: from)
        else { return nil }
        let connectors: Set<String> = between ? ["and"] : ["to", "until", "till", "-"]
        guard acceptAny(connectors) != nil,
            var second = try date(hint: .current, allowBare: from || between, allowTimeOnly: true, allowUnix: from),
            atEnd
        else { return nil }
        if first.isTimeOnly != second.isTimeOnly { return nil }
        if first.isTimeOnly, second.date < first.date,
            let next = calendar.date(byAdding: .day, value: 1, to: second.date)
        {
            second.date = next
        } else if !second.hasExplicitYear, !first.isTimeOnly, second.date < first.date, !tokens.contains("-"),
            let later = calendar.date(byAdding: .year, value: 1, to: second.date)
        {
            second.date = later
        }
        if tokens.contains("-"), !from, !between { swap(&first, &second) }
        let includeTime = first.hasTime || second.hasTime
        let span = second.date.timeIntervalSince(first.date)
        if includeTime {
            // The copied value keeps 12 significant digits of hours, so seconds survive.
            return Calculation(
                expression: "", result: CalendarFormat.breakdown(from: first.date, to: second.date, calendar: calendar, includeTime: true),
                detail: "\(Calculator.format(span / 3_600)) hours · \(Calculator.format(span)) seconds · Return to copy",
                value: Calculator.format(span / 3_600), kind: .duration)
        }
        let days = calendar.dateComponents([.day], from: first.date, to: second.date).day ?? 0
        return Calculation(
            expression: "", result: CalendarFormat.count(Double(days), "day", "days"),
            detail: "\(CalendarFormat.breakdown(from: first.date, to: second.date, calendar: calendar, includeTime: false)) · Return to copy",
            value: "\(days)", kind: .duration)
    }

    /// "today", "tomorrow", "now", "time", "next friday", "31 mar 2027", "2026-03-31T14:30:00Z".
    mutating func bareDate() throws -> Calculation? {
        if tokens == ["time"] || tokens == ["time", "now"] || tokens == ["current", "time"] {
            index = tokens.count
            return dateResult(ParsedDate(date: context.now, hasTime: true), timeOnly: true)
        }
        guard let parsed = try date(hint: .current, allowBare: false), atEnd else { return nil }
        return dateResult(parsed)
    }

    func dateResult(_ parsed: ParsedDate, timeOnly: Bool = false) -> Calculation {
        if timeOnly {
            return Calculation(
                expression: "", result: CalendarFormat.time(parsed.date, context: context),
                detail: "\(CalendarFormat.dayAndMonth(parsed.date, context: context)) · Return to copy", kind: .time,
                resultLabel: CalendarFormat.dayAndMonth(parsed.date, context: context), date: parsed.date)
        }
        let shown = describe(parsed.date, hasTime: parsed.hasTime)
        return Calculation(
            expression: "", result: shown,
            detail: "\(CalendarFormat.relative(parsed.date, context: context).capitalizedFirst) · Return to copy",
            kind: .date, date: parsed.date)
    }

    func describe(_ date: Date, hasTime: Bool) -> String {
        hasTime ? CalendarFormat.dateTime(date, context: context) : CalendarFormat.date(date, context: context)
    }

    // MARK: Durations

    mutating func duration() -> ParsedDuration? {
        var result = ParsedDuration()
        var matched = false
        var span: Double = 0
        while let term = attempt({ $0.durationTerm() }) {
            matched = true
            span += abs(term.amount) * (Self.unitSeconds[term.unit] ?? 0)
            // Terms past about 10,000 years would trap converting to Int, or stall the
            // search adding workdays. They still parse, so a complete phrase reports them.
            guard span <= Self.maximumSpan, abs(term.amount) <= (Self.maximumAmount[term.unit] ?? 0) else {
                sawOutOfRange = true
                _ = accept("and")
                continue
            }
            switch term.unit {
            case .workdays:
                let total = result.workdays + Int(term.amount)
                if abs(total) > DateMath.maximumWorkdays {
                    sawOutOfRange = true
                } else {
                    result.workdays = total
                }
            case .seconds: result.seconds += term.amount
            case .minutes: result.seconds += term.amount * 60
            case .hours: result.seconds += term.amount * 3_600
            case .days, .weeks:
                let days = term.amount * (term.unit == .weeks ? 7 : 1)
                result.parts.append((.day, Int(days.rounded(.towardZero))))
                result.seconds += (days - days.rounded(.towardZero)) * 86_400
            case .months, .years:
                guard term.amount == term.amount.rounded() else { return nil }
                result.parts.append((term.unit == .months ? .month : .year, Int(term.amount)))
            case .span: break
            }
            _ = accept("and")
        }
        return matched ? result : nil
    }

    mutating func durationTerm() -> (amount: Double, unit: CountUnit)? {
        guard let token = peek() else { return nil }
        if let groups = DateParser.attached.groups(in: token), let number = groups[1].flatMap(Double.init),
            number.isFinite, let unit = groups[2].flatMap({ Self.durationUnits[$0] })
        {
            index += 1
            return (number, unit)
        }
        guard let amount = Double(token) ?? Self.numberWords[token], amount.isFinite else { return nil }
        index += 1
        if accept("business", "days") || accept("business", "day") || accept("working", "days")
            || accept("work", "days")
        {
            return (amount, .workdays)
        }
        guard let word = peek(), let unit = Self.durationUnits[word] else { return nil }
        index += 1
        return (amount, unit)
    }

    func apply(_ duration: ParsedDuration, to date: Date, sign: Int) -> Date? {
        var result = date
        for (component, value) in duration.parts {
            guard let next = calendar.date(byAdding: component, value: sign * value, to: result) else { return nil }
            result = next
        }
        if duration.seconds != 0 { result = result.addingTimeInterval(Double(sign) * duration.seconds) }
        if duration.workdays != 0 {
            guard let next = DateMath.adding(workdays: sign * duration.workdays, to: result, calendar: calendar) else {
                return nil
            }
            result = next
        }
        return result
    }

    private static let attached = CalculatorPattern(#"^(\d+(?:\.\d+)?)([a-z]+)$"#)

    /// About 10,000 years, the most any date phrase may span.
    private static let maximumSpan: Double = 3.2e11

    private static let unitSeconds: [CountUnit: Double] = [
        .seconds: 1, .minutes: 60, .hours: 3_600, .days: 86_400, .weeks: 604_800, .months: 2_629_746,
        .years: 31_556_952, .workdays: 86_400 * 7 / 5,
    ]

    private static let maximumAmount: [CountUnit: Double] = [
        .seconds: maximumSpan, .minutes: maximumSpan / 60, .hours: maximumSpan / 3_600, .days: maximumSpan / 86_400,
        .weeks: maximumSpan / 604_800, .months: 120_000, .years: 10_000, .workdays: Double(DateMath.maximumWorkdays),
    ]

    /// Seconds since 1970 that a unix phrase may name: about year 5138 either way.
    static let maximumUnixSeconds: Double = 1e11

    /// A signed decimal number, as one token.
    mutating func acceptNumber() -> String? {
        guard let token = peek(), DateParser.signedNumber.groups(in: token) != nil else { return nil }
        index += 1
        return token
    }

    private static let signedNumber = CalculatorPattern(#"^[+-]?\d{1,16}(?:\.\d+)?$"#)

    private static let durationUnits: [String: CountUnit] = [
        "s": .seconds, "sec": .seconds, "secs": .seconds, "second": .seconds, "seconds": .seconds,
        "m": .minutes, "min": .minutes, "mins": .minutes, "minute": .minutes, "minutes": .minutes,
        "h": .hours, "hr": .hours, "hrs": .hours, "hour": .hours, "hours": .hours,
        "d": .days, "day": .days, "days": .days, "w": .weeks, "wk": .weeks, "wks": .weeks, "week": .weeks,
        "weeks": .weeks, "mo": .months, "month": .months, "months": .months, "y": .years, "yr": .years,
        "yrs": .years, "year": .years, "years": .years, "workday": .workdays, "workdays": .workdays,
        "weekday": .workdays, "weekdays": .workdays,
    ]

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    // MARK: Dates

    /// A date at the current token. `allowBare` also accepts a lone month or weekday
    /// name, which is only clearly a date after "until" or "since".
    mutating func date(hint: YearHint, allowBare: Bool, allowTimeOnly: Bool = false, allowUnix: Bool = false) throws
        -> ParsedDate?
    {
        if let leading = TimeOfDay.parse(tokens, at: index) {
            let start = index
            index += leading.length
            _ = accept("on")
            if var day = dayOnly(hint: hint, allowBare: allowBare), let date = leading.time.date(on: day.date, calendar: calendar) {
                day.date = date
                day.hasTime = true
                return day
            }
            index = start + leading.length
            if allowTimeOnly, let date = leading.time.date(on: today, calendar: calendar) {
                return ParsedDate(date: date, hasTime: true, isTimeOnly: true)
            }
            index = start
            return nil
        }
        if allowUnix, let token = peek(), Self.isTimestamp(token), let seconds = Double(token) {
            index += 1
            return ParsedDate(date: Date(timeIntervalSince1970: token.count >= 12 ? seconds / 1_000 : seconds), hasTime: true)
        }
        guard var day = dayOnly(hint: hint, allowBare: allowBare) else { return nil }
        if day.hasTime { return day }
        let beforeTime = index
        _ = accept("at")
        if let time = TimeOfDay.parse(tokens, at: index), let date = time.time.date(on: day.date, calendar: calendar) {
            index += time.length
            day.date = date
            day.hasTime = true
        } else {
            index = beforeTime
        }
        return day
    }

    mutating func dayOnly(hint: YearHint, allowBare: Bool) -> ParsedDate? {
        guard let token = peek() else { return nil }
        if let iso = isoDate(token) {
            index += 1
            return iso
        }
        switch token {
        case "today", "tonight":
            index += 1
            return ParsedDate(date: today)
        case "now":
            index += 1
            return ParsedDate(date: context.now, hasTime: true)
        case "tomorrow", "yesterday":
            index += 1
            return calendar.date(byAdding: .day, value: token == "tomorrow" ? 1 : -1, to: today).map { ParsedDate(date: $0) }
        default: break
        }
        if let relative = attempt({ $0.relativeDay() }) { return relative }
        if let holiday = attempt({ $0.holiday(hint: hint, allowBare: allowBare) }) { return holiday }
        if let edge = attempt({ $0.periodEdge() }) { return edge }
        if let explicit = attempt({ $0.explicitDate(hint: hint, allowBare: allowBare) }) { return explicit }
        if allowBare, let weekday = DateMath.weekdays[token] {
            index += 1
            return ParsedDate(date: nearest(weekday: weekday, hint: hint))
        }
        return nil
    }

    /// "next friday", "last monday", "this friday", "next week", "last month".
    mutating func relativeDay() -> ParsedDate? {
        guard let modifier = acceptAny(["next", "last", "this", "coming", "previous"]), let word = peek() else {
            return nil
        }
        index += 1
        if let weekday = DateMath.weekdays[word] {
            switch modifier {
            case "this":
                let monday = calendar.date(byAdding: .day, value: -mondayOffset(of: today), to: today) ?? today
                return calendar.date(byAdding: .day, value: (weekday + 5) % 7, to: monday).map { ParsedDate(date: $0) }
            case "last", "previous": return ParsedDate(date: nearest(weekday: weekday, hint: .past))
            default: return ParsedDate(date: nearest(weekday: weekday, hint: .future))
            }
        }
        let component: Calendar.Component
        switch word {
        case "week": component = .weekOfYear
        case "month": component = .month
        case "year": component = .year
        default: return nil
        }
        let value = modifier == "this" ? 0 : modifier == "last" || modifier == "previous" ? -1 : 1
        return calendar.date(byAdding: component, value: value, to: today).map { ParsedDate(date: $0) }
    }

    /// Christmas, New Year, Halloween, Valentine's Day and Easter. Alone they could be a
    /// search for a note or snippet, so they need `allowBare` or a year ("christmas 2027").
    mutating func holiday(hint: YearHint, allowBare: Bool) -> ParsedDate? {
        guard let rule = holidayRule() else { return nil }
        if let year = yearToken() {
            return validDate(rule(year)).map { ParsedDate(date: $0) }
        }
        return allowBare ? yearResolved(hint: hint, rule) : nil
    }

    /// The holiday at the current token, as its date in a given year.
    mutating func holidayRule() -> ((Int) -> DateComponents)? {
        let fixed: [([String], Int, Int)] = [
            (["christmas", "eve"], 12, 24), (["christmas", "day"], 12, 25), (["christmas"], 12, 25), (["xmas"], 12, 25),
            (["new", "year's", "eve"], 12, 31), (["new", "years", "eve"], 12, 31), (["nye"], 12, 31),
            (["new", "year's", "day"], 1, 1), (["new", "years", "day"], 1, 1), (["new", "year's"], 1, 1),
            (["new", "years"], 1, 1), (["new", "year"], 1, 1), (["halloween"], 10, 31),
            (["valentine's", "day"], 2, 14), (["valentines", "day"], 2, 14), (["valentines"], 2, 14),
            (["valentine's"], 2, 14),
        ]
        for (words, month, day) in fixed where accept(words) {
            return { DateComponents(year: $0, month: month, day: day) }
        }
        if accept("easter", "sunday") || accept("easter") {
            return { DateMath.easter(year: $0) }
        }
        return nil
    }

    mutating func accept(_ words: [String]) -> Bool {
        guard index + words.count <= tokens.count, Array(tokens[index..<(index + words.count)]) == words else {
            return false
        }
        index += words.count
        return true
    }

    /// "end of month", "end of the year", "start of next month".
    mutating func periodEdge() -> ParsedDate? {
        guard let edge = acceptAny(["end", "start", "beginning"]), accept("of") else { return nil }
        let shift = acceptAny(["next", "last", "this", "the"])
        guard let word = acceptAny(["month", "year", "week"]) else { return nil }
        let component: Calendar.Component = word == "month" ? .month : word == "year" ? .year : .weekOfYear
        let offset = shift == "next" ? 1 : shift == "last" ? -1 : 0
        let source = word == "week" ? isoCalendar : calendar
        guard let anchor = calendar.date(byAdding: component, value: offset, to: today),
            let interval = source.dateInterval(of: component, for: anchor)
        else { return nil }
        if edge == "end" {
            return calendar.date(byAdding: .day, value: -1, to: interval.end).map { ParsedDate(date: $0) }
        }
        return ParsedDate(date: interval.start)
    }

    /// "31 mar", "31st of march 2027", "march 31", "mar 31 2027", "march 2027", and a
    /// lone "march" when `allowBare`.
    mutating func explicitDate(hint: YearHint, allowBare: Bool) -> ParsedDate? {
        _ = accept("the")
        if let day = dayNumber(peek()) {
            index += 1
            _ = accept("of")
            guard let month = monthNumber(peek()) else { return nil }
            index += 1
            return build(day: day, month: month, year: yearToken(), hint: hint)
        }
        guard let month = monthNumber(peek()) else { return nil }
        index += 1
        if let day = dayNumber(peek()) {
            index += 1
            return build(day: day, month: month, year: yearToken(), hint: hint)
        }
        if let year = yearToken() { return build(day: 1, month: month, year: year, hint: hint) }
        guard allowBare else { return nil }
        return build(day: 1, month: month, year: nil, hint: hint)
    }

    mutating func yearToken() -> Int? {
        guard let token = peek(), token.count == 4, let year = Int(token), (1_000...9_999).contains(year) else {
            return nil
        }
        index += 1
        return year
    }

    mutating func build(day: Int, month: Int, year: Int?, hint: YearHint) -> ParsedDate? {
        if let year {
            guard let date = validDate(DateComponents(year: year, month: month, day: day)) else {
                sawInvalidDate = true
                return ParsedDate(date: today)
            }
            return ParsedDate(date: date)
        }
        guard let resolved = yearResolved(hint: hint, { DateComponents(year: $0, month: month, day: day) }) else {
            // February 29 resolves in some year; any other miss names a day that doesn't exist.
            sawInvalidDate = true
            return ParsedDate(date: today, hasExplicitYear: false)
        }
        return resolved
    }

    /// The date in this year, or the next or previous year that `hint` points to.
    func yearResolved(hint: YearHint, _ components: (Int) -> DateComponents) -> ParsedDate? {
        let year = calendar.component(.year, from: today)
        let candidates = (year - 8...year + 8).compactMap { validDate(components($0)) }
        let chosen: Date?
        switch hint {
        case .current: chosen = validDate(components(year)) ?? candidates.first { $0 >= today }
        case .future: chosen = candidates.first { $0 >= today }
        case .past: chosen = candidates.last { $0 <= today }
        }
        return chosen.map { ParsedDate(date: $0, hasExplicitYear: false) }
    }

    /// The date only if the calendar didn't have to normalize it (no February 30).
    func validDate(_ components: DateComponents, in calendar: Calendar? = nil) -> Date? {
        let calendar = calendar ?? self.calendar
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard check.year == components.year, check.month == components.month, check.day == components.day,
            components.hour == nil || check.hour == components.hour,
            components.minute == nil || check.minute == components.minute
        else { return nil }
        return date
    }

    /// A 2026-03-31 or 2026-03-31T14:30:00.250+01:00 token. A token shaped like ISO 8601
    /// with an impossible date, time or offset is reported as an invalid date instead of
    /// falling through to arithmetic.
    mutating func isoDate(_ token: String) -> ParsedDate? {
        guard let groups = DateMath.isoDate.groups(in: token) else { return nil }
        let invalid = { (parser: inout DateParser) -> ParsedDate in
            parser.sawInvalidDate = true
            return ParsedDate(date: parser.today)
        }
        guard let year = groups[1].flatMap(Int.init), let month = groups[2].flatMap(Int.init),
            let day = groups[3].flatMap(Int.init)
        else { return invalid(&self) }
        var zoned = calendar
        if let zone = groups[8], zone != "z" {
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let hours = Int(digits.prefix(2)) ?? 99
            let minutes = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 99 : 0
            guard hours <= 14, minutes < 60,
                let offset = TimeZone(secondsFromGMT: (hours * 3_600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1))
            else { return invalid(&self) }
            zoned.timeZone = offset
        } else if groups[8] == "z" {
            zoned.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        }
        let hour = groups[4].flatMap(Int.init)
        let minute = groups[5].flatMap(Int.init)
        let second = groups[6].flatMap(Int.init) ?? 0
        guard (0...23).contains(hour ?? 0), (0...59).contains(minute ?? 0), (0...59).contains(second),
            let date = validDate(
                DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0, second: second),
                in: zoned)
        else { return invalid(&self) }
        guard hour != nil else { return ParsedDate(date: date) }
        let fraction = groups[7].flatMap { Double("0" + $0) } ?? 0
        return ParsedDate(date: date.addingTimeInterval(fraction), hasTime: true)
    }

    func dayNumber(_ token: String?) -> Int? {
        guard var token else { return nil }
        for suffix in ["st", "nd", "rd", "th"] where token.hasSuffix(suffix) {
            token.removeLast(2)
            break
        }
        guard token.count <= 2, let day = Int(token), (1...31).contains(day) else { return nil }
        return day
    }

    func monthNumber(_ token: String?) -> Int? {
        guard var token else { return nil }
        if token.hasSuffix(".") { token.removeLast() }
        return DateMath.months[token]
    }

    /// The next (future) or previous (past) such weekday, never today.
    func nearest(weekday: Int, hint: YearHint) -> Date {
        let current = calendar.component(.weekday, from: today)
        let offset: Int
        if hint == .past {
            let back = (current - weekday + 7) % 7
            offset = -(back == 0 ? 7 : back)
        } else {
            let ahead = (weekday - current + 7) % 7
            offset = ahead == 0 ? 7 : ahead
        }
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// Days since Monday, for ISO-style weeks.
    func mondayOffset(of date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    var isoCalendar: Calendar {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        iso.locale = calendar.locale
        return iso
    }

    static func isTimestamp(_ token: String) -> Bool {
        (9...13).contains(token.count) && token.allSatisfy(\.isNumber)
    }
}

extension String {
    /// The string with its first letter uppercased.
    fileprivate var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
