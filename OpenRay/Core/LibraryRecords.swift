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

/// A named group of apps that a focus session blocks or allows.
struct FocusCategoryRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
}

// MARK: Slice 3: Emoji and Calculator

/// How often and how recently an emoji was used. `id` is the emoji itself.
struct EmojiUsageRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
}

/// A calculation the person kept.
struct CalculatorHistoryRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
}
