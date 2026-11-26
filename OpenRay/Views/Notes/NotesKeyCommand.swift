import AppKit

/// The Notes window's keyboard: navigation, pins and Markdown formatting. One table, so the
/// window, its menus and the tests agree.
enum NotesKeyCommand: Equatable, Sendable {
    case browse, newNote, back, forward, togglePin, openPinned(Int), toggleTask, close, deleteNote
    case bold, italic, strikethrough, code, link, heading(Int), bulletList, numberedList, taskList, quote, codeBlock

    /// The shortcut as the menu and help show it.
    var caps: String {
        switch self {
        case .browse: "⌘P"
        case .newNote: "⌘N"
        case .back: "⌘["
        case .forward: "⌘]"
        case .togglePin: "⇧⌘P"
        case .openPinned(let digit): "⌘\(digit)"
        case .toggleTask: "⌘↩"
        case .close: "⌘W"
        case .deleteNote: "⇧⌘⌫"
        case .bold: "⌘B"
        case .italic: "⌘I"
        case .strikethrough: "⇧⌘S"
        case .code: "⌘E"
        case .link: "⌘L"
        case .heading(let level): "⌥⌘\(level)"
        case .bulletList: "⇧⌘8"
        case .numberedList: "⇧⌘7"
        case .taskList: "⇧⌘9"
        case .quote: "⇧⌘B"
        case .codeBlock: "⌥⌘C"
        }
    }

    /// Digits by ANSI key code, so ⇧⌘7 is found even though ⇧7 types “&”.
    private static let digitKeyCodes: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    /// The command for a key press, or nil to let the editor have it.
    static func command(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NotesKeyCommand? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.control) else { return nil }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let key = characters?.lowercased() ?? ""

        if let digit = digitKeyCodes[keyCode] {
            switch (shift, option) {
            case (false, false): return .openPinned(digit)
            case (false, true): return (1...3).contains(digit) ? .heading(digit) : nil
            case (true, false):
                switch digit {
                case 7: return .numberedList
                case 8: return .bulletList
                case 9: return .taskList
                default: return nil
                }
            case (true, true): return nil
            }
        }
        if [36, 76].contains(keyCode) { return shift || option ? nil : .toggleTask }
        if keyCode == 51 { return shift && !option ? .deleteNote : nil }
        if keyCode == 33 || key == "[" { return shift || option ? nil : .back }
        if keyCode == 30 || key == "]" { return shift || option ? nil : .forward }

        switch (key, shift, option) {
        case ("p", false, false): return .browse
        case ("p", true, false): return .togglePin
        case ("n", false, false): return .newNote
        case ("w", false, false): return .close
        case ("b", false, false): return .bold
        case ("b", true, false): return .quote
        case ("i", false, false): return .italic
        case ("s", true, false): return .strikethrough
        case ("e", false, false): return .code
        case ("l", false, false): return .link
        case ("c", false, true): return .codeBlock
        default: return nil
        }
    }

    /// The edit a formatting command makes, or nil for commands that aren't edits.
    func edit(in text: String, selection: NSRange) -> NoteMarkdown.Edit? {
        switch self {
        case .bold: NoteMarkdown.toggleWrap("**", in: text, selection: selection)
        case .italic: NoteMarkdown.toggleWrap("_", in: text, selection: selection)
        case .strikethrough: NoteMarkdown.toggleWrap("~~", in: text, selection: selection)
        case .code: NoteMarkdown.toggleWrap("`", in: text, selection: selection)
        case .link: NoteMarkdown.insertLink(in: text, selection: selection)
        case .heading(let level): NoteMarkdown.setBlock(.heading(level), in: text, selection: selection)
        case .bulletList: NoteMarkdown.setBlock(.bulletList, in: text, selection: selection)
        case .numberedList: NoteMarkdown.setBlock(.numberedList, in: text, selection: selection)
        case .taskList: NoteMarkdown.setBlock(.taskList, in: text, selection: selection)
        case .quote: NoteMarkdown.setBlock(.quote, in: text, selection: selection)
        case .codeBlock: NoteMarkdown.codeBlock(in: text, selection: selection)
        case .toggleTask: NoteMarkdown.toggleTask(in: text, at: selection.location, selection: selection)
        default: nil
        }
    }
}
