import Foundation

// Placeholder records for the collections schema v5 declares. Each one belongs to the slice
// named above it, which grows it in place. Two rules for growing a record:
//
// 1. Add fields as optionals, or decode them with `decodeIfPresent` in a custom
//    `init(from:)`, so libraries saved before the field existed still load.
// 2. Keep `id` unique within its collection; `LibraryDatabase.validate()` checks it.
//
// The names end in Record so they don't collide with richer types a slice may define for its
// own logic (`WindowLayout` already names the built-in layouts).

// MARK: Slice 7: AI

/// A user-defined AI command: a prompt with placeholders and an output mode.
struct AICommandRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
}

/// An agent (formerly a preset): instructions, tools and a model setting.
struct AgentRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
}

// MARK: Slice 8: Script Commands

/// A folder of script commands.
struct ScriptDirectoryRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// The folder's absolute path. Empty only in placeholder records saved before Slice 8.
    var path: String = ""
    /// False keeps the folder in the list but leaves its scripts out of the launcher.
    var isEnabled = true
    var addedAt: Date? = nil

    init(id: UUID = UUID(), path: String = "", isEnabled: Bool = true, addedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }

    /// The folder, or nil for a record without a path.
    var url: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }

    private enum CodingKeys: String, CodingKey { case id, path, isEnabled, addedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt)
    }
}

// MARK: Slice 5: Window management

/// A saved multi-app window arrangement. Every field but `id` decodes if present, so the
/// ID-only records Step 0 wrote still load (as an empty, unnamed layout).
struct WindowLayoutRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name = ""
    /// Front to back: the first slot ends up frontmost.
    var slots: [SavedWindowLayout.Slot] = []
    var otherWindows: SavedWindowLayout.OtherWindows = .leave

    init(
        id: UUID = UUID(), name: String = "", slots: [SavedWindowLayout.Slot] = [],
        otherWindows: SavedWindowLayout.OtherWindows = .leave
    ) {
        self.id = id
        self.name = name
        self.slots = slots
        self.otherWindows = otherWindows
    }

    init(_ layout: SavedWindowLayout) {
        self.init(id: layout.id, name: layout.name, slots: layout.slots, otherWindows: layout.otherWindows)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        slots = try container.decodeIfPresent([SavedWindowLayout.Slot].self, forKey: .slots) ?? []
        // An option a later build adds reads as Leave Open rather than failing the library.
        otherWindows =
            (try? container.decodeIfPresent(SavedWindowLayout.OtherWindows.self, forKey: .otherWindows)) ?? .leave
    }

    /// The name to show: "Untitled Layout" until the person names it.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Layout" : trimmed
    }

    var layout: SavedWindowLayout {
        SavedWindowLayout(id: id, name: displayName, slots: slots, otherWindows: otherWindows)
    }
}

// MARK: Slice 6: Focus

/// A named group of apps that a focus session blocks or allows. `id` is `builtin.<name>` for an
/// edit to one of the built-in categories (see `FocusCategory.builtIns`), or a UUID string for one
/// the person made. Every other field is optional, so a record can override just what changed.
struct FocusCategoryRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String? = nil
    /// An SF Symbol name.
    var symbol: String? = nil
    /// The apps in the category, by bundle identifier.
    var bundleIDs: [String]? = nil
    /// True when the person removed a built-in category.
    var isHidden: Bool? = nil
}

// MARK: Slice 3: Emoji and Calculator

/// How often and how recently an emoji was used, and whether it's pinned or has custom
/// keywords. `id` is the emoji itself, without a skin tone. Every other field is optional,
/// so a record holds only what applies; `EmojiPreferences(records:)` reads them.
struct EmojiUsageRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// The decayed use score as of `lastUsed` (see `EmojiUsage`).
    var score: Double? = nil
    var count: Int? = nil
    var lastUsed: Date? = nil
    /// The emoji's place among pinned emoji, when it's pinned.
    var pinOrder: Int? = nil
    /// Extra search words.
    var keywords: [String]? = nil
}

/// A calculation the person copied or pasted, kept for three months (`CalculatorHistory`).
/// Records missing an expression, answer or date are skipped when read.
struct CalculatorHistoryRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// What was typed, such as "10 km in mi".
    var expression: String? = nil
    /// The answer as shown, such as "6.21371 mi".
    var result: String? = nil
    /// The answer ↩ copies, such as "6.21371192237".
    var value: String? = nil
    /// `Calculation.Kind`'s raw value.
    var kind: String? = nil
    var date: Date? = nil
}
