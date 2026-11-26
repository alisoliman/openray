import AppKit
import Foundation
import Testing

@testable import OpenRay

/// The Notes window's Markdown: styling ranges, task toggling, list continuation, formatting
/// commands, the `/` menu and the key map.
struct NotesMarkdownTests {
    private func spans(_ text: String, _ style: NoteMarkdown.Style) -> [NSRange] {
        NoteMarkdown.spans(in: text).filter { $0.style == style }.map(\.range)
    }

    private func substrings(_ text: String, _ style: NoteMarkdown.Style) -> [String] {
        spans(text, style).map { (text as NSString).substring(with: $0) }
    }

    // MARK: Styling ranges

    @Test func headingsStyleTheTextAndDimTheMarkers() {
        let text = "# Title\n## Sub heading\nplain"
        #expect(spans(text, .heading(1)) == [NSRange(location: 2, length: 5)])
        #expect(substrings(text, .heading(2)) == ["Sub heading"])
        #expect(Array(substrings(text, .syntax).prefix(2)) == ["# ", "## "])
        // Seven hashes or no space isn't a heading.
        #expect(spans("####### no\n#no", .heading(6)).isEmpty)
    }

    @Test func emphasisCodeAndStrikethroughHaveExactRanges() {
        let text = "a **bold** and _it_ and *also* `code` ~~gone~~"
        #expect(substrings(text, .bold) == ["bold"])
        #expect(substrings(text, .italic) == ["it", "also"])
        #expect(substrings(text, .code) == ["code"])
        #expect(substrings(text, .strikethrough) == ["gone"])
        // Each marker is dimmed: ** ** _ _ * * ` ` ~~ ~~.
        #expect(substrings(text, .syntax).sorted() == ["*", "*", "**", "**", "_", "_", "`", "`", "~~", "~~"].sorted())
        // Nothing inside code is styled again.
        #expect(substrings("`**not bold**`", .bold).isEmpty)
        // Intraword underscores stay plain, as in snake_case_names.
        #expect(substrings("snake_case_name", .italic).isEmpty)
        // A list marker isn't italic.
        #expect(substrings("* item *word*", .italic) == ["word"])
    }

    @Test func listsTasksQuotesAndRulesAreRecognized() {
        let text = "- one\n1. two\n- [ ] open\n- [x] done task\n> quoted\n---"
        #expect(substrings(text, .listMarker) == ["-", "1.", "-", "-"])
        #expect(substrings(text, .task(checked: false)) == ["[ ]"])
        #expect(substrings(text, .task(checked: true)) == ["[x]"])
        #expect(substrings(text, .completedTask) == ["done task"])
        #expect(substrings(text, .quote) == ["quoted"])
        #expect(substrings(text, .rule) == ["---"])
    }

    @Test func linksBareURLsAndImagesCarryTheirDestination() {
        let text = "see [docs](https://example.com/a) or https://openray.app. ![Shot](NoteAssets/A.png)"
        let links = NoteMarkdown.spans(in: text).compactMap { span -> String? in
            if case .link(let destination) = span.style { return "\((text as NSString).substring(with: span.range))→\(destination)" }
            return nil
        }
        #expect(links == ["docs→https://example.com/a", "https://openray.app→https://openray.app"])
        let images = NoteMarkdown.spans(in: text).compactMap { span -> String? in
            if case .image(let path) = span.style { return path }
            return nil
        }
        #expect(images == ["NoteAssets/A.png"])
    }

    @Test func fencedCodeBlocksCoverTheirLinesAndStopInlineStyling() {
        let text = "before\n```\nlet x = **y**\n```\nafter **b**"
        let block = spans(text, .codeBlock)
        #expect(block.count == 1)
        #expect((text as NSString).substring(with: block[0]) == "```\nlet x = **y**\n```")
        #expect(substrings(text, .bold) == ["b"])
        // An unclosed fence runs to the end while you type it.
        #expect(spans("```\nopen", .codeBlock) == [NSRange(location: 0, length: 8)])
    }

    @Test func rangesAreUTF16ForEmojiAndAccents() {
        let text = "😀 **é**"
        // 😀 is two UTF-16 units, then a space, then **.
        #expect(spans(text, .bold) == [NSRange(location: 5, length: 1)])
    }

    // MARK: Tasks

    @Test func commandReturnTogglesTheTaskOnTheCaretsLine() throws {
        let text = "Groceries\n- [ ] milk\n- [x] eggs"
        let check = try #require(NoteMarkdown.toggleTask(in: text, at: 14))
        #expect(check.applied(to: text) == "Groceries\n- [x] milk\n- [x] eggs")
        #expect(check.selection == NSRange(location: 14, length: 0))
        let uncheck = try #require(NoteMarkdown.toggleTask(in: text, at: (text as NSString).length))
        #expect(uncheck.applied(to: text) == "Groceries\n- [ ] milk\n- [ ] eggs")
        // Not a task: nothing to toggle.
        #expect(NoteMarkdown.toggleTask(in: text, at: 2) == nil)
        // Numbered and quoted tasks count too.
        #expect(NoteMarkdown.toggleTask(in: "1. [ ] a", at: 0)?.applied(to: "1. [ ] a") == "1. [x] a")
        #expect(NoteMarkdown.toggleTask(in: "> - [X] a", at: 0)?.applied(to: "> - [X] a") == "> - [ ] a")
    }

    @Test func aClickFindsTheTaskBoxUnderIt() {
        let text = "- [ ] call Sam"
        #expect(NoteMarkdown.taskBox(in: text, at: 3) == NSRange(location: 2, length: 3))
        #expect(NoteMarkdown.taskBox(in: text, at: 9) == nil)
    }

    // MARK: Return

    @Test func returnContinuesListsAndEndsEmptyItems() {
        #expect(NoteMarkdown.continuation(after: "- milk") == .continueWith("- "))
        #expect(NoteMarkdown.continuation(after: "  * nested") == .continueWith("  * "))
        #expect(NoteMarkdown.continuation(after: "9. ninth") == .continueWith("10. "))
        #expect(NoteMarkdown.continuation(after: "- [x] done") == .continueWith("- [ ] "))
        #expect(NoteMarkdown.continuation(after: "> quote") == .continueWith("> "))
        #expect(NoteMarkdown.continuation(after: "- ") == .endList(markerLength: 2))
        #expect(NoteMarkdown.continuation(after: "- [ ] ") == .endList(markerLength: 6))
        #expect(NoteMarkdown.continuation(after: "plain") == nil)

        let text = "- milk"
        let edit = NoteMarkdown.newline(in: text, at: 6)
        #expect(edit?.applied(to: text) == "- milk\n- ")
        #expect(edit?.selection == NSRange(location: 9, length: 0))
        // Mid-line, and inside code, ↩ is an ordinary line break.
        #expect(NoteMarkdown.newline(in: text, at: 3) == nil)
        #expect(NoteMarkdown.newline(in: "```\n- a", at: 7) == nil)
        // An empty item ends the list.
        #expect(NoteMarkdown.newline(in: "- a\n- ", at: 6)?.applied(to: "- a\n- ") == "- a\n")
    }

    // MARK: Formatting

    @Test func blocksApplyToEveryLineAndToggleOff() {
        let text = "one\ntwo"
        let all = NSRange(location: 0, length: 7)
        let bullets = NoteMarkdown.setBlock(.bulletList, in: text, selection: all)
        #expect(bullets.applied(to: text) == "- one\n- two")
        let numbered = NoteMarkdown.setBlock(.numberedList, in: "- one\n- two", selection: NSRange(location: 0, length: 11))
        #expect(numbered.applied(to: "- one\n- two") == "1. one\n2. two")
        #expect(NoteMarkdown.setBlock(.heading(2), in: "# Title", selection: NSRange(location: 3, length: 0)).applied(to: "# Title") == "## Title")
        // The same block again turns the lines back into paragraphs.
        #expect(NoteMarkdown.setBlock(.quote, in: "> a", selection: NSRange(location: 2, length: 0)).applied(to: "> a") == "a")
        #expect(NoteMarkdown.setBlock(.taskList, in: "- a", selection: NSRange(location: 0, length: 0)).applied(to: "- a") == "- [ ] a")
        // The caret keeps its place in the words.
        let caret = NoteMarkdown.setBlock(.heading(1), in: "Title", selection: NSRange(location: 2, length: 0))
        #expect(caret.selection == NSRange(location: 4, length: 0))
    }

    @Test func inlineMarkersWrapAndUnwrapTheSelection() {
        let wrapped = NoteMarkdown.toggleWrap("**", in: "a word", selection: NSRange(location: 2, length: 4))
        #expect(wrapped.applied(to: "a word") == "a **word**")
        #expect(wrapped.selection == NSRange(location: 4, length: 4))
        let unwrapped = NoteMarkdown.toggleWrap("**", in: "a **word**", selection: NSRange(location: 4, length: 4))
        #expect(unwrapped.applied(to: "a **word**") == "a word")
        // Nothing selected: a pair with the caret inside.
        let empty = NoteMarkdown.toggleWrap("`", in: "x", selection: NSRange(location: 1, length: 0))
        #expect(empty.applied(to: "x") == "x``")
        #expect(empty.selection == NSRange(location: 2, length: 0))
        let link = NoteMarkdown.insertLink(in: "see docs", selection: NSRange(location: 4, length: 4))
        #expect(link.applied(to: "see docs") == "see [docs]()")
        #expect(link.selection == NSRange(location: 11, length: 0))
        let image = NoteMarkdown.insertImage("NoteAssets/A.png", in: "text", selection: NSRange(location: 4, length: 0))
        #expect(image.applied(to: "text") == "text\n![Image](NoteAssets/A.png)\n")
    }

    // MARK: Slash menu

    @Test func slashTriggersAtLineStartOrAfterASpaceOnly() {
        #expect(NoteSlashCommand.trigger(in: "/", caret: 1)?.slash == 0)
        #expect(NoteSlashCommand.trigger(in: "/hea", caret: 4)?.query == "hea")
        #expect(NoteSlashCommand.trigger(in: "todo /ta", caret: 8)?.slash == 5)
        #expect(NoteSlashCommand.trigger(in: "and/or", caret: 6) == nil)
        #expect(NoteSlashCommand.trigger(in: "/a b", caret: 4) == nil)
        #expect(NoteSlashCommand.trigger(in: "line\n/q", caret: 7)?.slash == 5)
    }

    @Test func slashCommandsFilterAndRewriteTheLine() throws {
        #expect(NoteSlashCommand.matching("").count == NoteSlashCommand.allCases.count)
        #expect(NoteSlashCommand.matching("head").prefix(3) == [.heading1, .heading2, .heading3])
        #expect(NoteSlashCommand.matching("todo").first == .taskList)
        #expect(NoteSlashCommand.matching("zzz").isEmpty)

        let text = "Groceries /h1"
        let heading = try #require(NoteSlashCommand.heading1.edit(in: text, slash: 10, caret: 13))
        #expect(heading.applied(to: text) == "# Groceries ")
        let task = try #require(NoteSlashCommand.taskList.edit(in: "/", slash: 0, caret: 1))
        #expect(task.applied(to: "/") == "- [ ] ")
        #expect(task.selection == NSRange(location: 6, length: 0))
        let divider = try #require(NoteSlashCommand.divider.edit(in: "/div", slash: 0, caret: 4))
        #expect(divider.applied(to: "/div") == "---\n")
        let code = try #require(NoteSlashCommand.codeBlock.edit(in: "/code", slash: 0, caret: 5))
        #expect(code.applied(to: "/code") == "```\n\n```")
        #expect(NoteSlashCommand.image.edit(in: "/", slash: 0, caret: 1) == nil)
    }

    // MARK: Keys

    @Test func theKeyMapCoversNavigationPinsAndFormatting() {
        func command(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NotesKeyCommand? {
            NotesKeyCommand.command(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }
        #expect(command("p", 35, .command) == .browse)
        #expect(command("P", 35, [.command, .shift]) == .togglePin)
        #expect(command("n", 45, .command) == .newNote)
        #expect(command("[", 33, .command) == .back)
        #expect(command("]", 30, .command) == .forward)
        #expect(command("1", 18, .command) == .openPinned(1))
        #expect(command("0", 29, .command) == .openPinned(0))
        #expect(command("\r", 36, .command) == .toggleTask)
        #expect(command("&", 26, [.command, .shift]) == .numberedList)
        #expect(command("*", 28, [.command, .shift]) == .bulletList)
        #expect(command("(", 25, [.command, .shift]) == .taskList)
        #expect(command("2", 19, [.command, .option]) == .heading(2))
        #expect(command("b", 11, .command) == .bold)
        #expect(command("e", 14, .command) == .code)
        #expect(command("\u{7F}", 51, [.command, .shift]) == .deleteNote)
        // ⌘C, plain keys and ⌃ combinations go to the editor.
        #expect(command("c", 8, .command) == nil)
        #expect(command("p", 35, []) == nil)
        #expect(command("p", 35, [.command, .control]) == nil)
    }

    @Test func pinDigitsMapToSlotsBothWays() {
        #expect(NoteCollection.pinSlot(forDigit: 1) == 0)
        #expect(NoteCollection.pinSlot(forDigit: 9) == 8)
        #expect(NoteCollection.pinSlot(forDigit: 0) == 9)
        #expect(NoteCollection.digit(forPinSlot: 9) == 0)
        #expect(NoteCollection.digit(forPinSlot: 0) == 1)
        #expect(NoteCollection.digit(forPinSlot: 10) == nil)
    }
}
