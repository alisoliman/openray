import Foundation

struct QuickNote: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var modifiedAt: Date = .now

    // Added for the Notes window. Each is optional and decoded with decodeIfPresent, so libraries
    // saved before they existed load unchanged, and a note that never uses one encodes exactly as
    // it did before.

    /// The note's place among pinned notes, from 0. In the Notes window ⌘1 opens 0, ⌘9 opens 8
    /// and ⌘0 opens 9. Nil when the note isn't pinned.
    var pinnedIndex: Int? = nil
    /// When the note moved to Recently Deleted. Nil for a note that isn't deleted.
    var deletedAt: Date? = nil
    /// How the content is written: nil or 1 is plain text from the inline editor, 2 is Markdown
    /// from the Notes window. Plain text reads as Markdown too, so this only informs export.
    var formatVersion: Int? = nil

    /// Markdown, written in the Notes window.
    static let markdownFormat = 2
    /// The longest note the library stores.
    static let maximumLength = 100_000
    /// How long Recently Deleted keeps a note: 60 days.
    static let recentlyDeletedRetention: TimeInterval = 60 * 86_400
    /// ⌘1 … ⌘9 and ⌘0.
    static let maximumPins = 10

    /// The first non-empty line, without a Markdown heading's `#`s.
    static func derivedTitle(from content: String) -> String {
        let line = firstLine(of: content)
            .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        return String(line.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    private static func firstLine(of content: String) -> String {
        let line =
            content.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// The first line as a reader sees it: without heading, list, task or quote markers, emphasis
    /// or link syntax. An image alone on the first line reads “Image”.
    static func markdownTitle(from content: String) -> String {
        let line =
            content.split(whereSeparator: \.isNewline).lazy.map(String.init).first {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("```") && !trimmed.hasPrefix("~~~")
            } ?? ""
        var title = line.trimmingCharacters(in: .whitespaces)
        for pattern in [#"^#{1,6}\s+"#, #"^>\s?"#, #"^([-*+]|\d{1,9}[.)])\s+"#, #"^\[( |x|X)\]\s*"#] {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        title = title.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "Image", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        title = title.replacingOccurrences(of: #"(\*\*|__|~~|`)"#, with: "", options: .regularExpression)
        return String(title.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    var wordCount: Int {
        content.split { $0.isWhitespace || $0.isNewline }.count
    }

    var isDeleted: Bool { deletedAt != nil }
    var isPinned: Bool { pinnedIndex != nil }
    var isMarkdown: Bool { (formatVersion ?? 1) >= Self.markdownFormat }

    /// True while the title is just the first line, so it should follow the first line as it
    /// changes. A title the person typed in the inline editor stays.
    var titleFollowsContent: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty || title == Self.derivedTitle(from: content) || title == Self.markdownTitle(from: content)
            || title == String(Self.firstLine(of: content).prefix(80))
    }

    /// When Recently Deleted removes the note for good, or nil when it isn't deleted.
    var expiresAt: Date? { deletedAt.map { $0.addingTimeInterval(Self.recentlyDeletedRetention) } }
}

extension QuickNote {
    private enum CodingKeys: String, CodingKey {
        case id, title, content, modifiedAt, pinnedIndex, deletedAt, formatVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        pinnedIndex = try container.decodeIfPresent(Int.self, forKey: .pinnedIndex)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(pinnedIndex, forKey: .pinnedIndex)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encodeIfPresent(formatVersion, forKey: .formatVersion)
    }
}

/// Order, pins and Recently Deleted for the notes in the library. Pure functions over the
/// array, so the Notes window, the launcher and tests share one set of rules.
enum NoteCollection {
    /// Notes that aren't deleted: pinned ones first in pin order, then the most recently edited.
    static func ordered(_ notes: [QuickNote]) -> [QuickNote] {
        notes.filter { !$0.isDeleted }.sorted { lhs, rhs in
            switch (lhs.pinnedIndex, rhs.pinnedIndex) {
            case (let left?, let right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                return lhs.modifiedAt == rhs.modifiedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.modifiedAt > rhs.modifiedAt
            }
        }
    }

    /// Pinned notes in pin order.
    static func pinned(_ notes: [QuickNote]) -> [QuickNote] {
        notes.filter { !$0.isDeleted && $0.isPinned }.sorted { ($0.pinnedIndex ?? 0) < ($1.pinnedIndex ?? 0) }
    }

    /// Recently Deleted, most recently deleted first.
    static func deleted(_ notes: [QuickNote]) -> [QuickNote] {
        notes.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// The pin slot a ⌘-digit opens: ⌘1 is 0 … ⌘9 is 8, and ⌘0 is 9.
    static func pinSlot(forDigit digit: Int) -> Int? {
        guard (0...9).contains(digit) else { return nil }
        return digit == 0 ? 9 : digit - 1
    }

    /// The digit that opens a pin slot, for labels: 0 → “1”, 9 → “0”.
    static func digit(forPinSlot slot: Int) -> Int? {
        guard (0..<QuickNote.maximumPins).contains(slot) else { return nil }
        return slot == 9 ? 0 : slot + 1
    }

    enum PinError: LocalizedError, Equatable {
        case full, deleted, missing
        var errorDescription: String? {
            switch self {
            case .full: "You can pin up to \(QuickNote.maximumPins) notes. Unpin one first."
            case .deleted: "Restore this note before pinning it."
            case .missing: "This note no longer exists."
            }
        }
    }

    /// Pins a note in the next free slot, or unpins it and closes the gap so ⌘1… stay in order.
    /// Returns whether the note is pinned afterwards.
    @discardableResult
    static func togglePin(_ id: UUID, in notes: inout [QuickNote]) throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { throw PinError.missing }
        if notes[index].isPinned {
            notes[index].pinnedIndex = nil
            normalizePins(&notes)
            return false
        }
        guard !notes[index].isDeleted else { throw PinError.deleted }
        normalizePins(&notes)
        let count = notes.filter { !$0.isDeleted && $0.isPinned }.count
        guard count < QuickNote.maximumPins else { throw PinError.full }
        notes[index].pinnedIndex = count
        return true
    }

    /// Moves a pinned note one place earlier (-1) or later (+1).
    static func movePin(_ id: UUID, by offset: Int, in notes: inout [QuickNote]) {
        normalizePins(&notes)
        var order = pinned(notes).map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        guard to != from else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        for (slot, pinnedID) in order.enumerated() {
            if let index = notes.firstIndex(where: { $0.id == pinnedID }) { notes[index].pinnedIndex = slot }
        }
    }

    /// Renumbers pins 0, 1, 2… in their current order, unpins deleted notes, and drops pins past the limit.
    static func normalizePins(_ notes: inout [QuickNote]) {
        for index in notes.indices where notes[index].isDeleted { notes[index].pinnedIndex = nil }
        let order = pinned(notes).map(\.id)
        for (slot, id) in order.enumerated() {
            guard let index = notes.firstIndex(where: { $0.id == id }) else { continue }
            notes[index].pinnedIndex = slot < QuickNote.maximumPins ? slot : nil
        }
    }

    /// Moves a note to Recently Deleted. Its pin is released.
    static func moveToRecentlyDeleted(_ id: UUID, at date: Date, in notes: inout [QuickNote]) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isDeleted else { return }
        notes[index].deletedAt = date
        notes[index].pinnedIndex = nil
        normalizePins(&notes)
    }

    /// Brings a note back from Recently Deleted.
    static func restore(_ id: UUID, at date: Date, in notes: inout [QuickNote]) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].deletedAt = nil
        notes[index].modifiedAt = date
    }

    /// Notes in Recently Deleted for 60 days or more at `now`.
    static func expired(_ notes: [QuickNote], now: Date) -> [QuickNote] {
        notes.filter { note in note.expiresAt.map { $0 <= now } ?? false }
    }
}

extension LibraryDatabase {
    /// Notes that aren't in Recently Deleted. Root search, the Notes scope and favorites list only these.
    var liveNotes: [QuickNote] { notes.filter { !$0.isDeleted } }

    /// Deleting a note from the launcher moves it to Recently Deleted, as the Notes window does.
    mutating func moveNoteToRecentlyDeleted(_ id: UUID, at date: Date = .now) {
        NoteCollection.moveToRecentlyDeleted(id, at: date, in: &notes)
    }
}
