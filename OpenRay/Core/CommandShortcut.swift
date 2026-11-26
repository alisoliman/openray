import Carbon
import Foundation

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let all: Self = [.command, .control, .option, .shift]

    init(rawValue: UInt32) { self.rawValue = rawValue }

    init(carbonFlags: UInt32) {
        var modifiers: Self = []
        if carbonFlags & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonFlags & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        if carbonFlags & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonFlags & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        self = modifiers
    }

    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

/// A shortcut made of modifier keys alone, which Carbon can't register. `ModifierHotKeys`
/// detects them from modifier changes.
enum ShortcutGesture: String, Codable, Hashable, Sendable {
    /// Press the modifiers together and release them without another key: ⌥⌘, or Right ⌘.
    case modifiersOnly
    /// Tap one modifier twice quickly: ⌘ ⌘.
    case doubleTap
}

/// Physical modifier keys, for gestures where the side matters (Right ⌘ rather than either ⌘).
struct ModifierSides: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let leftCommand = Self(rawValue: 1 << 0)
    static let rightCommand = Self(rawValue: 1 << 1)
    static let leftOption = Self(rawValue: 1 << 2)
    static let rightOption = Self(rawValue: 1 << 3)
    static let leftControl = Self(rawValue: 1 << 4)
    static let rightControl = Self(rawValue: 1 << 5)
    static let leftShift = Self(rawValue: 1 << 6)
    static let rightShift = Self(rawValue: 1 << 7)

    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Every key, in ⌃ ⌥ ⇧ ⌘ order, left before right.
    static let ordered: [(side: ModifierSides, modifier: ShortcutModifiers, symbol: String, isRight: Bool)] = [
        (.leftControl, .control, "⌃", false), (.rightControl, .control, "⌃", true),
        (.leftOption, .option, "⌥", false), (.rightOption, .option, "⌥", true),
        (.leftShift, .shift, "⇧", false), (.rightShift, .shift, "⇧", true),
        (.leftCommand, .command, "⌘", false), (.rightCommand, .command, "⌘", true),
    ]

    /// The modifiers these keys hold, whichever side.
    var modifiers: ShortcutModifiers {
        Self.ordered.reduce(into: []) { result, entry in if contains(entry.side) { result.insert(entry.modifier) } }
    }

    /// How many physical keys are down.
    var count: Int { rawValue.nonzeroBitCount }
}

struct CommandShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    /// Nil for a key with modifiers, which Carbon registers. Otherwise a gesture of modifier keys alone.
    var gesture: ShortcutGesture? = nil
    /// For a gesture, the physical keys when the side matters; nil means either side.
    var sides: ModifierSides? = nil

    /// The key code gestures store, since they have no key.
    static let gestureKeyCode: UInt32 = 0xFFFF

    static func modifiersOnly(_ modifiers: ShortcutModifiers, sides: ModifierSides? = nil) -> CommandShortcut {
        CommandShortcut(keyCode: gestureKeyCode, modifiers: modifiers, gesture: .modifiersOnly, sides: sides)
    }

    static func doubleTap(_ modifier: ShortcutModifiers, side: ModifierSides? = nil) -> CommandShortcut {
        CommandShortcut(keyCode: gestureKeyCode, modifiers: modifier, gesture: .doubleTap, sides: side)
    }

    /// Whether Carbon can register it: a key, with or without modifiers.
    var isKeyChord: Bool { gesture == nil }

    /// Whether a press of exactly these keys completes this gesture. The gesture detector's rule:
    /// a sided gesture needs exactly its keys; an unsided one takes either side of each of its
    /// modifiers, and no other key.
    func isMatched(byPress pressed: ModifierSides) -> Bool {
        guard gesture != nil else { return false }
        if let sides { return sides == pressed }
        return pressed.modifiers == modifiers && pressed.count == modifiers.rawValue.nonzeroBitCount
    }

    /// Every press that completes this gesture.
    var matchingPresses: [ModifierSides] {
        guard gesture != nil else { return [] }
        if let sides { return [sides] }
        var presses: [ModifierSides] = [[]]
        for entry in ModifierSides.ordered where !entry.isRight && modifiers.contains(entry.modifier) {
            guard let right = ModifierSides.ordered.first(where: { $0.modifier == entry.modifier && $0.isRight })
            else { continue }
            presses = presses.flatMap { [$0.union(entry.side), $0.union(right.side)] }
        }
        return presses
    }

    /// Whether two modifier gestures would both fire from one press, by the detector's own rule:
    /// two of the same kind that some press completes, or a double tap and a single-key gesture
    /// its second tap completes. Only one of such a pair can work.
    func gestureOverlaps(_ other: CommandShortcut) -> Bool {
        guard let gesture, let otherGesture = other.gesture else { return false }
        let shared = matchingPresses.filter(other.isMatched(byPress:))
        if gesture == otherGesture { return !shared.isEmpty }
        // A double tap fires only for one key, on a press that is also a single tap.
        return shared.contains { $0.count == 1 }
    }

    var usesPrintableKey: Bool { isKeyChord && Self.printableKeyCodes.contains(keyCode) }

    /// Worded keys (“⌘ Return”), for messages. Gestures use their caps.
    var title: String {
        gesture == nil ? (modifierSymbols + [keyTitle]).joined(separator: " ") : caps.joined(separator: " ")
    }

    /// Keycaps: the modifiers in ⌃ ⌥ ⇧ ⌘ order, then one cap for the key, so
    /// “Page Up” and “Keypad 1” stay whole and Return, Delete and Esc use their glyphs.
    /// Gestures show their modifiers, sided ones as “Right ⌘”, and a double tap twice.
    var caps: [String] {
        if let gesture {
            let symbols = gestureSymbols
            return gesture == .doubleTap ? symbols + symbols : symbols
        }
        let key =
            switch keyCode {
            case 36: "↩"
            case 51: "⌫"
            case 53: "esc"
            default: keyTitle
            }
        return modifierSymbols + [key]
    }

    /// What a printable key types on the current layout, without Shift and not
    /// uppercased, so menu key equivalents keep keys such as “ß”. Nil for other keys
    /// and off the main thread.
    var layoutCharacter: String? {
        // Read the active input source only on the main thread. Background library validation
        // can still produce an error safely using the stable hardware label.
        guard Thread.isMainThread, usesPrintableKey,
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: characters, count: length)
        guard !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return label
    }

    /// 1 through 20 for the function keys F1–F20, otherwise nil.
    var functionKeyNumber: Int? { Self.functionKeyNumbers[keyCode] }

    private var modifierSymbols: [String] {
        let symbols: [(ShortcutModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.compactMap { modifiers.contains($0.0) ? $0.1 : nil }
    }

    /// A gesture's keys: sided ones say which side, others as plain modifiers.
    private var gestureSymbols: [String] {
        guard let sides else { return modifierSymbols }
        return ModifierSides.ordered.compactMap { entry in
            sides.contains(entry.side) ? (entry.isRight ? "Right \(entry.symbol)" : "Left \(entry.symbol)") : nil
        }
    }

    private var keyTitle: String {
        layoutCharacter?.uppercased() ?? Self.keyNames[keyCode] ?? "Unknown Key"
    }

    func validate() throws {
        guard modifiers.subtracting(.all).isEmpty else {
            throw LibraryValidationError("Use Command, Control, Option or Shift.")
        }
        if let gesture {
            guard keyCode == Self.gestureKeyCode, !modifiers.isEmpty,
                sides.map({ $0.modifiers == modifiers }) ?? true
            else {
                throw LibraryValidationError("This modifier shortcut isn't complete. Record it again.")
            }
            switch gesture {
            case .doubleTap:
                guard modifiers.rawValue.nonzeroBitCount == 1, (sides?.count ?? 1) == 1 else {
                    throw LibraryValidationError("Double-tap one modifier key, such as ⌘ ⌘.")
                }
            case .modifiersOnly:
                // A single modifier on its own would fire on every use of it, unless one side is chosen.
                guard modifiers.rawValue.nonzeroBitCount >= 2 || sides?.count == 1 else {
                    throw LibraryValidationError("Use two modifiers together, or one side of a modifier, such as Right ⌘.")
                }
            }
            return
        }
        guard Self.keyNames[keyCode] != nil else {
            throw LibraryValidationError("Use Command, Control, Option or Shift together with a standard key.")
        }
        // A key alone works only for the keys nothing types: F13 to F20.
        guard !modifiers.isEmpty || Self.bareFunctionKeys.contains(keyCode) else {
            throw LibraryValidationError(
                "Use Command, Control, Option or Shift together with a standard key, or F13 to F20 alone.")
        }
        guard !CommandShortcutPolicy.fixedReservedShortcuts.contains(self) else {
            throw LibraryValidationError("\(title) is reserved by macOS. Choose another shortcut.")
        }
    }

    /// F13–F20, which can be shortcuts on their own.
    static let bareFunctionKeys = Set<UInt32>([kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].map(UInt32.init))

    // Hardware key codes are persisted, so identities never depend on localized key labels.
    // Modifier keys, Fn/Globe, and media keys are deliberately absent.
    private static let printableKeyCodes = Set<UInt32>(0...35).union(37...47).union([50, 93, 94])
    private static let functionKeyNumbers: [UInt32: Int] = Dictionary(
        uniqueKeysWithValues: [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ].enumerated().map { (UInt32($0.element), $0.offset + 1) })
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 64: "F17", 65: "Keypad .",
        67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Enter", 78: "Keypad −",
        79: "F18", 80: "F19", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2",
        85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 90: "F20",
        91: "Keypad 8", 92: "Keypad 9", 93: "¥", 94: "_", 95: "Keypad ,", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 102: "Eisu", 103: "F11", 104: "Kana", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 110: "Menu", 111: "F12", 113: "F15", 114: "Help",
        115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2",
        121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

extension LauncherHotKey {
    var shortcut: CommandShortcut {
        let modifiers: ShortcutModifiers =
            switch self {
            case .optionSpace: .option
            case .controlSpace: .control
            case .controlOptionSpace: [.control, .option]
            }
        return CommandShortcut(keyCode: UInt32(kVK_Space), modifiers: modifiers)
    }
}

enum CommandShortcutPolicy {
    // Apple lists these system actions at https://support.apple.com/en-us/102650.
    // Configurable system shortcuts are additionally checked via CopySymbolicHotKeys.
    static let fixedReservedShortcuts: Set<CommandShortcut> = {
        var shortcuts: Set<CommandShortcut> = [
            .init(keyCode: UInt32(kVK_Space), modifiers: .command),
            .init(keyCode: UInt32(kVK_Space), modifiers: [.option, .command]),
            .init(keyCode: UInt32(kVK_Space), modifiers: [.control, .command]),
            .init(keyCode: UInt32(kVK_Tab), modifiers: .command),
            .init(keyCode: UInt32(kVK_Tab), modifiers: [.shift, .command]),
            .init(keyCode: UInt32(kVK_ANSI_Grave), modifiers: .command),
            .init(keyCode: UInt32(kVK_ANSI_Grave), modifiers: [.shift, .command]),
            .init(keyCode: UInt32(kVK_Escape), modifiers: [.option, .command]),
            .init(keyCode: UInt32(kVK_Escape), modifiers: [.option, .shift, .command]),
            .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.control, .command]),
            .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.shift, .command]),
            .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.option, .shift, .command]),
            .init(keyCode: UInt32(kVK_ANSI_D), modifiers: [.option, .command]),
        ]
        for code in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6] {
            shortcuts.insert(.init(keyCode: UInt32(code), modifiers: [.shift, .command]))
            if code != kVK_ANSI_5 {
                shortcuts.insert(.init(keyCode: UInt32(code), modifiers: [.control, .shift, .command]))
            }
        }
        return shortcuts
    }()

    static func validate(shortcut: CommandShortcut, reservedShortcuts: Set<CommandShortcut>) throws {
        try shortcut.validate()
        guard !reservedShortcuts.contains(shortcut) else {
            throw LibraryValidationError(
                "\(shortcut.title) is enabled as a macOS system shortcut. Choose another shortcut.")
        }
    }

    @MainActor
    static func systemReservedShortcuts() -> Set<CommandShortcut> {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr, let values else { return [] }
        let hotKeys = values.takeRetainedValue() as NSArray
        return Set(
            hotKeys.compactMap { entry in
                guard let entry = entry as? [String: Any],
                    (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
                    let code = entry[kHISymbolicHotKeyCode] as? NSNumber,
                    let flags = entry[kHISymbolicHotKeyModifiers] as? NSNumber,
                    flags.uint32Value & ~ShortcutModifiers.all.carbonFlags == 0
                else { return nil }
                return CommandShortcut(keyCode: code.uint32Value, modifiers: .init(carbonFlags: flags.uint32Value))
            })
    }

    static func conflictWarnings(for shortcut: CommandShortcut) -> [String] {
        if shortcut.gesture == .modifiersOnly, shortcut.sides == nil {
            return [
                "\(shortcut.title) fires whenever you press and release those modifiers without another key, even while you're working in another app."
            ]
        }
        if shortcut.usesPrintableKey, [.shift, .option, [.shift, .option]].contains(shortcut.modifiers) {
            return [
                "\(shortcut.title) is also used for typing. Saving it may prevent that character from being typed while OpenRay is running."
            ]
        }
        let commonKeys: Set<UInt32> = [0, 1, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 17, 31, 34, 35, 37, 46, 43]
        guard shortcut.modifiers.contains(.command), commonKeys.contains(shortcut.keyCode) else { return [] }
        return [
            "\(shortcut.title) is commonly used by apps. Saving it may override that action while OpenRay is running."
        ]
    }
}
