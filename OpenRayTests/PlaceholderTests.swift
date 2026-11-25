import Foundation
import Testing

@testable import OpenRay

/// 2022-06-15 13:44:39 UTC, a Wednesday: the date the public placeholder reference uses.
private let referenceDate = Date(timeIntervalSince1970: 1_655_300_679)

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func values(
    clipboard: [String] = [], selection: String? = nil, snippets: [String: String] = [:],
    arguments: [PlaceholderArgument.ID: String] = [:], now: Date = referenceDate,
    locale: Locale = Locale(identifier: "en_US")
) -> PlaceholderValues {
    PlaceholderValues(
        now: now, calendar: utcCalendar, locale: locale, clipboard: clipboard, selection: selection,
        snippets: snippets, arguments: arguments,
        calculator: { expression in
            // A tiny evaluator for "a op b" so the tests don't depend on the app's calculator.
            let parts = expression.split(separator: " ")
            guard parts.count == 3, let a = Double(parts[0]), let b = Double(parts[2]) else { return nil }
            switch parts[1] {
            case "+": return String(format: "%g", a + b)
            case "*": return String(format: "%g", a * b)
            default: return nil
            }
        },
        uuid: { UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")! })
}

private func render(
    _ text: String, _ context: PlaceholderContext = .snippet, _ source: PlaceholderValues = values()
) -> PlaceholderRendering {
    Placeholders.render(text, context: context, source: source)
}

struct PlaceholderParsingTests {
    @Test(arguments: [
        "Plain text", "if x { return y }", #"{"name": "value"}"#, "{ date }x{", "}{", "{}", "{ }", "{1}",
        "{unknown}", "{Date}", "a { color: red }", "back\\slash \\{x\\}", "",
    ])
    func textWithoutPlaceholdersIsUnchanged(_ text: String) {
        let template = PlaceholderTemplate(text, context: .snippet)
        #expect(!template.hasPlaceholders || text == "{ date }x{")
        if !template.hasPlaceholders {
            #expect(template.parseIssues.isEmpty)
            #expect(render(text).text == text)
        }
    }

    @Test func spacesInsideBracesAreAllowed() {
        let template = PlaceholderTemplate("{ date }x{", context: .snippet)
        #expect(template.placeholders.map(\.kind) == [.date])
    }

    @Test func everyDocumentedPlaceholderParses() {
        let text = """
            {clipboard}{clipboard offset=2}{selection}{snippet name="Sig"}{argument}{cursor}\
            {date}{time}{datetime}{day}{uuid}{calculator expression="1 + 1"}{browser-tab}
            """
        let kinds = PlaceholderTemplate(text, context: .snippet).placeholders.map(\.kind)
        #expect(
            kinds == [
                .clipboard, .clipboard, .selection, .snippet, .argument, .cursor, .date, .time, .datetime, .day,
                .uuid, .calculator, .browserTab,
            ])
    }

    @Test func attributeValuesAcceptEveryQuoteStyle() {
        let template = PlaceholderTemplate(
            #"{argument name="a b" default=“x y” options='p, q'}{argument name=bare}{snippet name="say \"hi\" \\ ok"}"#,
            context: .snippet)
        let tokens = template.placeholders.map(\.token)
        #expect(
            tokens[0]
                == .argument(PlaceholderArgument(id: .named("a b"), defaultValue: "x y", options: ["p", "q"])))
        #expect(tokens[1] == .argument(PlaceholderArgument(id: .named("bare"))))
        #expect(tokens[2] == .snippet(name: #"say "hi" \ ok"#))
    }

    @Test func modifiersChainInOrder() throws {
        let placeholder = try #require(
            PlaceholderTemplate("{clipboard | trim |uppercase| percent-encode | json-stringify | raw}", context: .text)
                .placeholders.first)
        #expect(placeholder.modifiers == [.trim, .uppercase, .percentEncode, .jsonStringify, .raw])
    }

    @Test(arguments: [
        "{clipboard | shout}", "{clipboard foo=1}", "{clipboard offset=-1}", "{clipboard offset=x}",
        "{date format=\"yyyy\" locale=\"fr-FR\"}", "{date locale=\"en_US\"}", "{date locale=\"xx-YY\"}",
        "{date offset=\"+ 2d\"}", "{date offset=\"3x\"}", "{snippet}", "{snippet name=\"\"}", "{cursor | trim}",
        "{argument options=\",,\"}", "{selection x=1}", "{date offset=1d offset=2d}", "{calculator}",
        "{argument name=\"unterminated}", "{uuid | }",
    ])
    func malformedKnownPlaceholdersStayLiteralAndAreReported(_ text: String) {
        let template = PlaceholderTemplate(text, context: .snippet)
        #expect(!template.hasPlaceholders)
        #expect(template.parseIssues.count == 1)
        #expect(render(text).text == text)
    }

    @Test func dateOffsetsParseSignsAndCaseSensitiveUnits() {
        let offsets = PlaceholderDateOffset.parse("+2y +5M -3d 4h -30m")
        #expect(
            offsets == [
                .init(amount: 2, unit: .year), .init(amount: 5, unit: .month), .init(amount: -3, unit: .day),
                .init(amount: 4, unit: .hour), .init(amount: -30, unit: .minute),
            ])
        #expect(PlaceholderDateOffset.parse("+ 2d") == nil)
        #expect(PlaceholderDateOffset.parse("") == nil)
        #expect(PlaceholderDateOffset.parse("+2w") == nil)
        #expect(PlaceholderDateOffset.parse("+1234567d") == nil)
    }

    @Test func backslashEscapesAPlaceholderOnly() {
        #expect(render(#"\{clipboard} and {clipboard}"#, .snippet, values(clipboard: ["X"])).text == "{clipboard} and X")
        #expect(render(#"\{not a placeholder}"#).text == #"\{not a placeholder}"#)
        #expect(render(#"C:\{uuid}"#).text == "C:{uuid}")
        #expect(render("ends with \\").text == "ends with \\")
    }

    @Test func placeholdersNeverSpanLines() {
        #expect(!PlaceholderTemplate("{date\n}", context: .snippet).hasPlaceholders)
        #expect(!PlaceholderTemplate("{argument name=\"a\nb\"}", context: .snippet).hasPlaceholders)
    }

    @Test func rangesPointAtTheSource() throws {
        let source = "Hi {argument name=\"who\"}, it's {day}."
        let template = PlaceholderTemplate(source, context: .snippet)
        #expect(template.placeholders.map { String(source[$0.range]) } == ["{argument name=\"who\"}", "{day}"])
        #expect(template.placeholders.map(\.source) == ["{argument name=\"who\"}", "{day}"])
    }

    @Test func quicklinksTreatQueryAndBareNamesAsArguments() {
        let link = PlaceholderTemplate("shortcuts://run-shortcut?Name={Test}&q={query | raw}", context: .quicklink)
        #expect(link.arguments.map(\.id) == [.named("Test"), .named("query")])
        #expect(link.placeholders.last?.modifiers == [.raw])
        #expect(!PlaceholderTemplate("{query}", context: .snippet).hasPlaceholders)
        #expect(!PlaceholderTemplate("{Test}", context: .aiCommand).hasPlaceholders)
        #expect(!PlaceholderTemplate("{Test x=1}", context: .quicklink).hasPlaceholders)
    }

    @Test func pathologicalInputParsesQuicklyAndUnchanged() {
        let inputs = [
            String(repeating: "{date \"", count: 8_000) + String(repeating: "{", count: 8_000),
            "{date format=\"" + String(repeating: "x {date a=1 ", count: 8_000),
            String(repeating: "{argument name=\"", count: 8_000),
            String(repeating: "\\{", count: 20_000),
        ]
        let clock = ContinuousClock()
        let start = clock.now
        for text in inputs {
            #expect(render(text).text == text)
            #expect(render(text, .quicklink).text == text)
        }
        #expect(clock.now - start < .seconds(5))
    }
}

struct PlaceholderRenderingTests {
    @Test func defaultDateAndTimeMatchTheLegacySnippetTokens() {
        let content = "Today {date}, at {time}; {unknown}"
        let legacy = Snippet(name: "Date", keyword: ";d", content: content).expanded(
            at: referenceDate, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(render(content).text == legacy)
        #expect(render("{date}").text == "Jun 15, 2022")
    }

    @Test func dateTimeAndWeekday() {
        #expect(render("{day}").text == "Wednesday")
        #expect(render("{datetime}").text.hasPrefix("Jun 15, 2022"))
        #expect(render("{datetime}").text.contains("1:44"))
        #expect(render("{time format=\"HH:mm:ss\"}").text == "13:44:39")
    }

    @Test(arguments: [
        ("{date format=\"yyyy-MM-dd\"}", "2022-06-15"),
        ("{date format=\"yyyy-MM-dd\" offset=\"+3M -5d\"}", "2022-09-10"),
        ("{date format=\"yyyy-MM-dd\" offset=\"+2y +5M\"}", "2024-11-15"),
        ("{time format=\"HH:mm\" offset=\"+3h +30m\"}", "17:14"),
        ("{datetime format=\"yyyy-MM-dd HH:mm\" offset=+1h}", "2022-06-15 14:44"),
        ("{datetime format=\"yyyy-MM-dd HH:mm\" offset=\"-14m\"}", "2022-06-15 13:30"),
        ("{day offset=-3d}", "Sunday"),
        ("{date format=\"h:mm 'on the eve of' MMMM d\"}", "1:44 on the eve of June 15"),
        ("{date format=\"MM/dd/yyyy\"}", "06/15/2022"),
        ("{date format=\"yyyy-MM-dd'T'HH:mm:ssZ\"}", "2022-06-15T13:44:39+0000"),
        ("{date format=\"EEEE, MMM d, yyyy\"}", "Wednesday, Jun 15, 2022"),
    ])
    func formatsAndOffsets(_ template: String, _ expected: String) {
        #expect(render(template).text == expected)
    }

    @Test func monthOffsetsClampToTheMonthEnd() {
        let january31 = Date(timeIntervalSince1970: 1_643_587_200)  // 2022-01-31 00:00 UTC
        #expect(render("{date format=\"yyyy-MM-dd\" offset=\"+1M\"}", .snippet, values(now: january31)).text == "2022-02-28")
    }

    @Test func localeAttributeLocalizesOutput() {
        #expect(render("{date locale=\"fr-FR\"}").text == "15 juin 2022")
        #expect(render("{day locale=\"de-DE\"}").text == "Mittwoch")
        #expect(render("{day locale=\"fr-FR\" offset=\"+1d\"}").text == "jeudi")
        #expect(render("{date}", .snippet, values(locale: Locale(identifier: "de_DE"))).text == "15.06.2022")
    }

    @Test func clipboardOffsetsReadOlderEntries() {
        let source = values(clipboard: ["newest", "older", "oldest"])
        #expect(render("{clipboard}|{clipboard offset=1}|{clipboard offset=2}", .text, source).text == "newest|older|oldest")
        let missing = render("[{clipboard offset=5}]", .text, source)
        #expect(missing.text == "[]")
        #expect(missing.issues == [.unavailable(.clipboard)])
        #expect(render("[{clipboard}]", .text, values()).text == "[]")
    }

    @Test func selectionIsLazyAndOptional() {
        #expect(render("“{selection}”", .text, values(selection: "picked")).text == "“picked”")
        #expect(render("{selection}", .text, values()).issues == [.unavailable(.selection)])

        struct CountingSource: PlaceholderDataSource {
            let counter = Counter()
            func selectedText() -> String? {
                counter.calls += 1
                return "x"
            }
        }
        final class Counter: @unchecked Sendable { var calls = 0 }
        let source = CountingSource()
        _ = Placeholders.render("{date}", context: .text, source: source)
        #expect(source.counter.calls == 0)
        _ = Placeholders.render("{selection}{selection}", context: .text, source: source)
        #expect(source.counter.calls == 2)
    }

    @Test func snippetsRenderTheirPlaceholdersButDoNotNest() {
        let source = values(
            clipboard: ["clip"],
            snippets: [
                "Signature": "Regards, {argument name=\"sender\" default=\"Ann\"} on {day}{cursor}",
                "Loop": "before {snippet name=\"Signature\"} after",
            ])
        let rendered = render("Hello\n{snippet name=\"signature\"} — {clipboard}", .snippet, source)
        #expect(rendered.text == "Hello\nRegards, Ann on Wednesday — clip")
        #expect(rendered.cursorUTF16Offset == nil)
        #expect(rendered.arguments.map(\.id) == [.named("sender")])

        let nested = render("{snippet name=\"Loop\"}", .snippet, source)
        #expect(nested.text == "before  after")
        #expect(nested.issues == [.nestedSnippet("Signature")])

        let missing = render("[{snippet name=\"Nope\"}]", .snippet, source)
        #expect(missing.text == "[]")
        #expect(missing.issues == [.missingSnippet("Nope")])
    }

    @Test func argumentsShareValuesByNameAndFallBackToDefaults() {
        let template = "{argument name=\"tone\" default=\"happy\"} {argument name=\"tone\"} {argument name=\"topic\"}"
        let filled = render(template, .snippet, values(arguments: [.named("tone"): "calm", .named("topic"): "tea"]))
        #expect(filled.text == "calm calm tea")
        #expect(filled.arguments.map(\.title) == ["tone", "topic"])
        #expect(filled.arguments.first?.defaultValue == "happy")
        #expect(filled.issues.isEmpty)

        let defaults = render(template, .snippet, values(arguments: [.named("tone"): ""]))
        #expect(defaults.text == "happy happy ")
        #expect(defaults.missingArguments == ["topic"])
    }

    @Test func laterOccurrencesContributeMissingDefaultsAndOptions() {
        let template = PlaceholderTemplate(
            "{argument name=\"x\"}{argument name=\"x\" default=\"d\" options=\"a, b, a, \"}", context: .snippet)
        #expect(template.arguments == [PlaceholderArgument(id: .named("x"), defaultValue: "d", options: ["a", "b"])])
        #expect(template.arguments.first?.isRequired == false)
    }

    @Test func unnamedArgumentsAreDistinctInputs() {
        let template = PlaceholderTemplate("{argument} and {argument default=\"two\"}", context: .snippet)
        #expect(template.arguments.map(\.id) == [.unnamed(1), .unnamed(2)])
        #expect(template.arguments.map(\.title) == ["Argument", "Argument"])
        let rendered = template.render(values(arguments: [.unnamed(1): "one"]))
        #expect(rendered.text == "one and two")
    }

    @Test func atMostThreeDistinctArguments() {
        let text = "{argument name=\"a\"}{argument name=\"b\"}{argument name=\"a\"}{argument name=\"c\"}{argument name=\"d\"}"
        let template = PlaceholderTemplate(text, context: .snippet)
        #expect(template.arguments.map(\.title) == ["a", "b", "c"])
        #expect(template.validationIssues == [.tooManyArguments("{argument name=\"d\"}")])
        let rendered = template.render(
            values(arguments: [.named("a"): "1", .named("b"): "2", .named("c"): "3", .named("d"): "4"]))
        #expect(rendered.text == "1213{argument name=\"d\"}")
        #expect(rendered.issues == [.tooManyArguments("{argument name=\"d\"}")])
    }

    @Test func cursorIsHonoredOnlyInSnippets() throws {
        let rendered = render("console.log({cursor});")
        #expect(rendered.text == "console.log();")
        #expect(rendered.cursorOffset == 12)
        #expect(rendered.charactersAfterCursor == 2)

        let link = render("https://x.com/{cursor}a", .quicklink)
        #expect(link.text == "https://x.com/a")
        #expect(link.cursorUTF16Offset == nil)
        #expect(link.issues == [.notHonored(.cursor)])
        #expect(PlaceholderTemplate("{cursor}", context: .quicklink).validationIssues == [.notHonored(.cursor)])
    }

    @Test func cursorOffsetsCountCharactersNotCodeUnits() {
        let rendered = render("👩‍💻 é{cursor}😀 x")
        #expect(rendered.text == "👩‍💻 é😀 x")
        #expect(rendered.cursorOffset == 3)
        #expect(rendered.charactersAfterCursor == 3)
        #expect(rendered.cursorUTF16Offset == "👩‍💻 é".utf16.count)
    }

    @Test func onlyTheFirstCursorCounts() {
        let rendered = render("a{cursor}b{cursor}c")
        #expect(rendered.text == "abc")
        #expect(rendered.cursorOffset == 1)
        #expect(rendered.issues == [.duplicateCursor])
        #expect(PlaceholderTemplate("{cursor}{cursor}", context: .snippet).validationIssues == [.duplicateCursor])
    }

    @Test func uuidsComeFromTheSource() {
        #expect(render("{uuid}").text == "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        let random = Placeholders.render("{uuid} {uuid}", context: .text, source: PlaceholderValues())
        let parts = random.text.split(separator: " ")
        #expect(parts.count == 2 && parts[0] != parts[1] && parts.allSatisfy { UUID(uuidString: String($0)) != nil })
    }

    @Test func calculatorEvaluatesItsRenderedExpression() {
        let template = PlaceholderTemplate("Total: {calculator expression=\"{argument name='n'} * 3\"}", context: .snippet)
        #expect(template.arguments.map(\.id) == [.named("n")])
        let rendered = template.render(values(arguments: [.named("n"): "14"]))
        #expect(rendered.text == "Total: 42")
        #expect(rendered.arguments.map(\.id) == [.named("n")])

        let failed = render("[{calculator expression=\"1 / 0\"}]")
        #expect(failed.text == "[]")
        #expect(failed.issues == [.calculationFailed("1 / 0")])
    }

    @Test func browserTabIsReportedAsUnsupported() {
        let rendered = render("Summarize {browser-tab format=\"markdown\"}", .aiCommand)
        #expect(rendered.text == "Summarize ")
        #expect(rendered.unsupportedPlaceholders == [.browserTab])
        #expect(PlaceholderTemplate("{browser-tab}", context: .aiCommand).validationIssues == [.unsupported(.browserTab)])
    }

    @Test(arguments: [
        ("{clipboard | uppercase}", "  Foo \"Bar\" ", "  FOO \"BAR\" "),
        ("{clipboard | lowercase}", "Foo Bar", "foo bar"),
        ("{clipboard | trim}", " \n Foo Bar \t", "Foo Bar"),
        ("{clipboard | percent-encode}", "Foo Bar/é?&", "Foo%20Bar%2F%C3%A9%3F%26"),
        ("{clipboard | json-stringify}", "Foo \"Bar\"", "\"Foo \\\"Bar\\\"\""),
        ("{clipboard | json-stringify}", "line\nbreak\\ / tab\t", "\"line\\nbreak\\\\ / tab\\t\""),
        ("{clipboard | trim | uppercase}", "  hi  ", "HI"),
        ("{clipboard | uppercase | json-stringify}", "a\"b", "\"A\\\"B\""),
        ("{clipboard | raw}", "Foo Bar", "Foo Bar"),
    ])
    func modifiers(_ template: String, _ clipboard: String, _ expected: String) {
        #expect(render(template, .text, values(clipboard: [clipboard])).text == expected)
    }

    @Test func quicklinksPercentEncodeUnlessRawOrAlreadyEncoded() {
        let source = values(clipboard: ["a b&c"], arguments: [.named("q"): "Foo Bar"])
        #expect(render("https://x.com/?q={argument name=\"q\"}", .quicklink, source).text == "https://x.com/?q=Foo%20Bar")
        #expect(render("https://x.com/{clipboard | raw}", .quicklink, source).text == "https://x.com/a b&c")
        #expect(render("https://x.com/{clipboard | percent-encode}", .quicklink, source).text == "https://x.com/a%20b%26c")
        #expect(render("{date}", .quicklink, source).text == "Jun%2015%2C%202022")
        #expect(
            render("{clipboard}", .quicklink, source, ).text
                == render("{clipboard}", .text, source).text.addingPercentEncoding(
                    withAllowedCharacters: PlaceholderEncoding.unreserved))
        let unformatted = PlaceholderTemplate("~/{clipboard}", context: .quicklink).render(
            source, options: .init(appliesContextFormatting: false))
        #expect(unformatted.text == "~/a b&c")
    }

    @Test func legacyQuicklinkQueryMatchesTheOldEncoding() throws {
        let link = Quicklink(name: "Search", template: "https://duckduckgo.com/?q={query}", keyword: "d")
        let query = "swift & café/100%"
        let legacy = try link.resolvedURL(query: query).absoluteString
        #expect(render(link.template, .quicklink, values(arguments: [.named("query"): query])).text == legacy)
    }

    @Test func snippetsAndTextInsertValuesAsIs() {
        let source = values(clipboard: ["a b&c"])
        #expect(render("{clipboard}", .snippet, source).text == "a b&c")
        #expect(render("{clipboard}", .text, source).text == "a b&c")
    }

    @Test func aiCommandsQuoteContentButNotDates() {
        let source = values(clipboard: ["notes"], selection: "Hello")
        #expect(render("Fix {selection}", .aiCommand, source).text == "Fix \"\"\"Hello\"\"\"")
        #expect(render("Fix {selection | raw}", .aiCommand, source).text == "Fix Hello")
        #expect(render("{selection | json-stringify}", .aiCommand, source).text == "\"Hello\"")
        #expect(render("On {date format=\"yyyy\"}", .aiCommand, source).text == "On 2022")
        #expect(render("[{argument default=\"\"}]", .aiCommand, source).text == "[]")
    }

    @Test func longValuesAreCut() {
        let source = values(clipboard: [String(repeating: "x", count: 50)])
        let rendered = PlaceholderTemplate("{clipboard}", context: .text).render(
            source, options: .init(maximumValueLength: 10))
        #expect(rendered.text == String(repeating: "x", count: 10))
    }

    @Test func insertedValuesAreNeverReparsed() {
        let source = values(clipboard: ["{uuid} {clipboard}"], arguments: [.unnamed(1): "{date}"])
        #expect(render("{clipboard} {argument}", .text, source).text == "{uuid} {clipboard} {date}")
    }

    @Test func issueMessagesAreReadable() {
        let issues: [PlaceholderIssue] = [
            .invalid("{date x}"), .tooManyArguments("{argument}"), .notHonored(.cursor), .unsupported(.browserTab),
            .duplicateCursor, .missingSnippet("A"), .nestedSnippet("B"), .missingArgument("C"),
            .calculationFailed("1/0"), .unavailable(.selection),
        ]
        #expect(issues.allSatisfy { !$0.message.isEmpty && $0.message.hasSuffix(".") })
        #expect(Placeholder.Kind.suggested(in: .quicklink).contains(.cursor) == false)
        #expect(Placeholder.Kind.suggested(in: .snippet).contains(.cursor))
        #expect(Placeholder.Kind.allCases.allSatisfy { PlaceholderTemplate($0.insertionText, context: .snippet).hasPlaceholders || $0 == .snippet || $0 == .argument || $0 == .calculator })
    }
}
