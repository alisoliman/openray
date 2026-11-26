import Foundation
import Observation

/// One message as saved.
struct StoredChatMessage: Codable, Equatable, Sendable {
    var id: UUID
    /// "user" or "assistant".
    var role: String
    var text: String
    var displayText: String?
    var attachmentLabels: [String]?
    var isPartial: Bool?

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role == .user ? "user" : "assistant"
        text = message.text
        displayText = message.displayText
        attachmentLabels = message.attachmentLabels.isEmpty ? nil : message.attachmentLabels
        isPartial = message.isPartial ? true : nil
    }

    var message: ChatMessage {
        ChatMessage(
            id: id, role: role == "user" ? .user : .assistant, text: text, isPartial: isPartial ?? false,
            displayText: displayText, attachmentLabels: attachmentLabels ?? [])
    }
}

/// A saved chat. Kept in `chats.json` beside `library.json`, never in the library itself.
struct SavedChat: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var messages: [StoredChatMessage] = []
    /// Its place among pinned chats (⌘1–⌘9), when pinned.
    var pinOrder: Int? = nil
    var isArchived = false
    /// Set while it's in Recently Deleted.
    var deletedAt: Date? = nil
    var agentID: UUID? = nil
    /// The rolling summary of turns that no longer fit the model's window.
    var summary: String? = nil
    var summarizedMessageCount = 0
    /// The FoundationModels transcript as JSON (`Transcript` is `Codable`). Nil rebuilds the
    /// session from the summary and recent messages.
    var transcript: Data? = nil
    /// The chat this one was branched from.
    var branchedFrom: UUID? = nil

    var isPinned: Bool { pinOrder != nil }
    var isDeleted: Bool { deletedAt != nil }

    var state: AIConversationState {
        AIConversationState(
            messages: messages.map(\.message), summary: summary, summarizedMessageCount: summarizedMessageCount,
            agentID: agentID, transcript: transcript)
    }

    /// The first question, as a title.
    static func derivedTitle(for messages: [ChatMessage]) -> String {
        let first = messages.first { $0.role == .user }.map { $0.displayText ?? $0.text } ?? ""
        let title = QuickNote.derivedTitle(from: first)
        return title.isEmpty ? "New Chat" : title
    }
}

/// How long chats are kept after they were last used.
enum ChatRetention: String, CaseIterable, Identifiable, Sendable {
    case forever, days30, days90, year

    var id: String { rawValue }
    var title: String {
        switch self {
        case .forever: "Forever"
        case .days30: "30 days"
        case .days90: "90 days"
        case .year: "1 year"
        }
    }
    var days: Int? {
        switch self {
        case .forever: nil
        case .days30: 30
        case .days90: 90
        case .year: 365
        }
    }
}

/// Saved chats: the chat window's sidebar, pins, archive and Recently Deleted.
@MainActor
@Observable
final class ChatStore {
    /// Deleted chats stay this long before they're gone for good.
    static let recentlyDeletedDays = 30
    static let fileName = "chats.json"

    private(set) var chats: [SavedChat] = []
    /// Why chats can't be saved, such as an unreadable file. Nil when all is well.
    private(set) var errorMessage: String?
    /// True when the file couldn't be read: nothing is written over it.
    private(set) var isReadOnly = false
    @ObservationIgnored let fileURL: URL?

    private struct File: Codable {
        var version = 1
        var chats: [SavedChat]
    }

    /// `fileURL` nil keeps chats in memory only (tests and verification).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    /// `chats.json` beside the library file.
    static func url(nextTo libraryURL: URL) -> URL {
        libraryURL.deletingLastPathComponent().appending(path: fileName)
    }

    // MARK: Reading

    func chat(id: UUID) -> SavedChat? { chats.first { $0.id == id } }

    /// Chats in the sidebar: not archived, not deleted, newest first.
    var recent: [SavedChat] { chats.filter { !$0.isArchived && !$0.isDeleted }.sorted { $0.updatedAt > $1.updatedAt } }
    var pinned: [SavedChat] {
        chats.filter { $0.isPinned && !$0.isDeleted }.sorted { ($0.pinOrder ?? 0) < ($1.pinOrder ?? 0) }
    }
    var archived: [SavedChat] { chats.filter { $0.isArchived && !$0.isDeleted }.sorted { $0.updatedAt > $1.updatedAt } }
    var recentlyDeleted: [SavedChat] {
        chats.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// The pinned chat ⌘`number` opens.
    func pinned(at number: Int) -> SavedChat? {
        let pins = pinned
        return (1...9).contains(number) && number <= pins.count ? pins[number - 1] : nil
    }

    enum Scope: Sendable { case recent, archived, recentlyDeleted }

    /// Chats whose title or messages contain every word of `query`.
    func search(_ query: String, in scope: Scope = .recent) -> [SavedChat] {
        let pool: [SavedChat] =
            switch scope {
            case .recent: recent
            case .archived: archived
            case .recentlyDeleted: recentlyDeleted
            }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return pool }
        return pool.filter { chat in
            let text = ([chat.title] + chat.messages.map { $0.displayText ?? $0.text }).joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    // MARK: Writing

    /// Saves a conversation into a chat, creating it when `id` is new. Returns the chat.
    @discardableResult
    func save(_ state: AIConversationState, id: UUID?, now: Date = .now) -> SavedChat? {
        let messages = state.messages.map(StoredChatMessage.init)
        guard !messages.isEmpty else { return nil }
        var chat = id.flatMap(self.chat(id:)) ?? SavedChat(id: id ?? UUID(), title: SavedChat.derivedTitle(for: state.messages), createdAt: now)
        chat.messages = messages
        chat.summary = state.summary
        chat.summarizedMessageCount = state.summarizedMessageCount
        chat.agentID = state.agentID
        chat.transcript = state.transcript
        chat.updatedAt = now
        chat.deletedAt = nil
        upsert(chat)
        return persist() ? chat : nil
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.title = String(trimmed.prefix(120)) }
    }

    /// Pins at the end of the pinned list. At most nine pins, one per ⌘-number.
    func pin(_ id: UUID) {
        guard let chat = self.chat(id: id), !chat.isPinned, !chat.isDeleted else { return }
        guard pinned.count < 9 else {
            errorMessage = "You can pin up to nine chats, one for each of ⌘1–⌘9. Unpin one first."
            return
        }
        let next = (pinned.compactMap(\.pinOrder).max() ?? -1) + 1
        mutate(id) { $0.pinOrder = next }
    }

    func unpin(_ id: UUID) {
        mutate(id) { $0.pinOrder = nil }
        renumberPins()
        persist()
    }

    /// Moves a pinned chat up or down by one.
    func movePin(_ id: UUID, by offset: Int) {
        var pins = pinned.map(\.id)
        guard let index = pins.firstIndex(of: id) else { return }
        let target = min(max(0, index + offset), pins.count - 1)
        pins.swapAt(index, target)
        for (order, pinID) in pins.enumerated() {
            if let position = chats.firstIndex(where: { $0.id == pinID }) { chats[position].pinOrder = order }
        }
        persist()
    }

    func archive(_ id: UUID) {
        mutate(id) {
            $0.isArchived = true
            $0.pinOrder = nil
        }
        renumberPins()
        persist()
    }

    func unarchive(_ id: UUID) { mutate(id) { $0.isArchived = false } }

    /// Moves a chat to Recently Deleted, where it stays for thirty days.
    func delete(_ id: UUID, now: Date = .now) {
        mutate(id) {
            $0.deletedAt = now
            $0.pinOrder = nil
        }
        renumberPins()
        persist()
    }

    func restore(_ id: UUID) { mutate(id) { $0.deletedAt = nil } }

    func deletePermanently(_ id: UUID) {
        chats.removeAll { $0.id == id }
        persist()
    }

    func emptyRecentlyDeleted() {
        chats.removeAll(where: \.isDeleted)
        persist()
    }

    /// Removes every chat, the deleted ones included.
    func deleteAll() {
        chats = []
        persist()
    }

    /// A new chat with the messages up to and including `messageID`. It keeps the summary
    /// only when the branch point comes after everything the summary stands for, and starts
    /// a fresh model session, rebuilt from those messages.
    @discardableResult
    func branch(_ id: UUID, through messageID: UUID, now: Date = .now) -> SavedChat? {
        guard let source = self.chat(id: id), let index = source.messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        let messages = Array(source.messages[...index])
        let keepsSummary = source.summarizedMessageCount <= messages.count
        let branch = SavedChat(
            title: "\(source.title) (branch)", createdAt: now, updatedAt: now, messages: messages, agentID: source.agentID,
            summary: keepsSummary ? source.summary : nil,
            summarizedMessageCount: keepsSummary ? source.summarizedMessageCount : 0, transcript: nil,
            branchedFrom: source.id)
        upsert(branch)
        return persist() ? branch : nil
    }

    /// Applies the retention setting and empties Recently Deleted of chats older than thirty days.
    func purge(retention: ChatRetention, now: Date = .now) {
        let calendar = Calendar.current
        var changed = false
        if let days = retention.days, let cutoff = calendar.date(byAdding: .day, value: -days, to: now) {
            for index in chats.indices where !chats[index].isDeleted && !chats[index].isPinned && chats[index].updatedAt < cutoff {
                chats[index].deletedAt = now
                changed = true
            }
        }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.recentlyDeletedDays, to: now) {
            let before = chats.count
            chats.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
            changed = changed || chats.count != before
        }
        if changed { persist() }
    }

    // MARK: Storage

    private func upsert(_ chat: SavedChat) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = chat } else { chats.append(chat) }
    }

    private func mutate(_ id: UUID, _ change: (inout SavedChat) -> Void) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        change(&chats[index])
        persist()
    }

    private func renumberPins() {
        for (order, pin) in pinned.enumerated() {
            if let index = chats.firstIndex(where: { $0.id == pin.id }) { chats[index].pinOrder = order }
        }
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(File.self, from: data)
            guard file.version <= 1 else {
                isReadOnly = true
                errorMessage = "Your chats were saved by a newer OpenRay. They're shown read-only."
                chats = file.chats
                return
            }
            chats = file.chats
        } catch {
            // Never write over a file that couldn't be read.
            isReadOnly = true
            errorMessage = "Saved chats couldn't be read, so new chats won't be saved. \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let fileURL else { return true }
        guard !isReadOnly else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(File(chats: chats))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Chats couldn't be saved. \(error.localizedDescription)"
            return false
        }
    }
}
