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

struct CommandShortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers

    var usesPrintableKey: Bool { Self.printableKeyCodes.contains(keyCode) }

    var title: String {
        let symbols: [(ShortcutModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return (symbols.compactMap { modifiers.contains($0.0) ? $0.1 : nil } + [keyTitle])
            .joined(separator: " ")
    }

    private var keyTitle: String {
        let fallback = Self.keyNames[keyCode] ?? "Unknown Key"
        // Read the active input source only on the main thread. Background library validation
        // can still produce an error safely using the stable hardware label.
        guard Thread.isMainThread, usesPrintableKey,
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return fallback }
        let label = String(utf16CodeUnits: characters, count: length)
        guard !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return fallback }
        return label.uppercased()
    }

    func validate() throws {
        guard !modifiers.isEmpty, modifiers.subtracting(.all).isEmpty,
            Self.keyNames[keyCode] != nil
        else {
            throw LibraryValidationError("Use Command, Control, Option, or Shift together with a standard key.")
        }
        guard modifiers != .all else {
            throw LibraryValidationError("Hyper Key shortcuts with all four modifiers are not supported.")
        }
        guard !CommandShortcutPolicy.fixedReservedShortcuts.contains(self) else {
            throw LibraryValidationError("\(title) is reserved by macOS. Choose another shortcut.")
        }
    }

    // Hardware key codes are persisted, so identities never depend on localized key labels.
    // Modifier keys, Fn/Globe, and media keys are deliberately absent.
    private static let printableKeyCodes = Set<UInt32>(0...35).union(37...47).union([50, 93, 94])
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
