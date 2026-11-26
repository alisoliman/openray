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
    /// Makes every write fail with this reason, so tests can check nothing is lost.
    @ObservationIgnored var writeFailureForTesting: String?

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
    //
    // Every change builds the next list of chats, writes it, and only then publishes it, so
    // what's on screen is never ahead of what's on disk. Each returns false when it couldn't
    // be saved, with the reason in `errorMessage`.

    enum SaveRefusal: Equatable {
        /// The chat was deleted for good; saving would bring it back.
        case removed
        /// The chat is in Recently Deleted, which is read-only until it's restored.
        case inRecentlyDeleted
    }

    /// Why a conversation with this chat id can't be saved, or nil when it can.
    func refusal(forSaving id: UUID?) -> SaveRefusal? {
        guard let id else { return nil }
        guard let chat = chat(id: id) else { return .removed }
        return chat.isDeleted ? .inRecentlyDeleted : nil
    }

    /// Saves a conversation: into the existing chat `id`, or a new chat when `id` is nil. A
    /// chat that was deleted, or is in Recently Deleted, is never written or brought back.
    @discardableResult
    func save(_ state: AIConversationState, id: UUID?, now: Date = .now) -> SavedChat? {
        let messages = state.messages.map(StoredChatMessage.init)
        guard !messages.isEmpty, refusal(forSaving: id) == nil else { return nil }
        var chat = id.flatMap(self.chat(id:)) ?? SavedChat(title: SavedChat.derivedTitle(for: state.messages), createdAt: now)
        chat.messages = messages
        chat.summary = state.summary
        chat.summarizedMessageCount = state.summarizedMessageCount
        chat.agentID = state.agentID
        chat.transcript = state.transcript
        chat.updatedAt = now
        var next = chats
        if let index = next.firstIndex(where: { $0.id == chat.id }) { next[index] = chat } else { next.append(chat) }
        return commit(next) ? chat : nil
    }

    @discardableResult
    func rename(_ id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mutate(id) { $0.title = String(trimmed.prefix(120)) }
    }

    /// Pins at the end of the pinned list. At most nine pins, one per ⌘-number.
    @discardableResult
    func pin(_ id: UUID) -> Bool {
        guard let chat = self.chat(id: id), !chat.isPinned, !chat.isDeleted else { return false }
        guard pinned.count < 9 else {
            errorMessage = "You can pin up to nine chats, one for each of ⌘1–⌘9. Unpin one first."
            return false
        }
        let next = (pinned.compactMap(\.pinOrder).max() ?? -1) + 1
        return mutate(id) { $0.pinOrder = next }
    }

    @discardableResult
    func unpin(_ id: UUID) -> Bool { mutate(id, renumbering: true) { $0.pinOrder = nil } }

    /// Moves a pinned chat up or down by one.
    @discardableResult
    func movePin(_ id: UUID, by offset: Int) -> Bool {
        var pins = pinned.map(\.id)
        guard let index = pins.firstIndex(of: id) else { return false }
        let target = min(max(0, index + offset), pins.count - 1)
        pins.swapAt(index, target)
        var next = chats
        for (order, pinID) in pins.enumerated() {
            if let position = next.firstIndex(where: { $0.id == pinID }) { next[position].pinOrder = order }
        }
        return commit(next)
    }

    @discardableResult
    func archive(_ id: UUID) -> Bool {
        mutate(id, renumbering: true) {
            $0.isArchived = true
            $0.pinOrder = nil
        }
    }

    @discardableResult
    func unarchive(_ id: UUID) -> Bool { mutate(id) { $0.isArchived = false } }

    /// Moves a chat to Recently Deleted, where it stays for thirty days, read-only.
    @discardableResult
    func delete(_ id: UUID, now: Date = .now) -> Bool {
        mutate(id, renumbering: true) {
            $0.deletedAt = now
            $0.pinOrder = nil
        }
    }

    @discardableResult
    func restore(_ id: UUID) -> Bool { mutate(id) { $0.deletedAt = nil } }

    @discardableResult
    func deletePermanently(_ id: UUID) -> Bool { commit(chats.filter { $0.id != id }) }

    @discardableResult
    func emptyRecentlyDeleted() -> Bool { commit(chats.filter { !$0.isDeleted }) }

    /// Removes every chat, the deleted ones included.
    @discardableResult
    func deleteAll() -> Bool { commit([]) }

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
        return commit(chats + [branch]) ? branch : nil
    }

    /// Applies the retention setting and empties Recently Deleted of chats older than thirty days.
    func purge(retention: ChatRetention, now: Date = .now) {
        let calendar = Calendar.current
        var next = chats
        if let days = retention.days, let cutoff = calendar.date(byAdding: .day, value: -days, to: now) {
            for index in next.indices where !next[index].isDeleted && !next[index].isPinned && next[index].updatedAt < cutoff {
                next[index].deletedAt = now
            }
        }
        if let cutoff = calendar.date(byAdding: .day, value: -Self.recentlyDeletedDays, to: now) {
            next.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
        }
        if next != chats { commit(next) }
    }

    // MARK: Storage

    private func mutate(_ id: UUID, renumbering: Bool = false, _ change: (inout SavedChat) -> Void) -> Bool {
        var next = chats
        guard let index = next.firstIndex(where: { $0.id == id }) else { return false }
        change(&next[index])
        if renumbering { Self.renumberPins(&next) }
        return commit(next)
    }

    private static func renumberPins(_ chats: inout [SavedChat]) {
        let pinned = chats.indices.filter { chats[$0].isPinned && !chats[$0].isDeleted }
            .sorted { (chats[$0].pinOrder ?? 0) < (chats[$1].pinOrder ?? 0) }
        for (order, index) in pinned.enumerated() { chats[index].pinOrder = order }
    }

    /// Writes `next`, then publishes it. Nothing changes when the write fails.
    @discardableResult
    private func commit(_ next: [SavedChat]) -> Bool {
        guard persist(next) else { return false }
        chats = next
        return true
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

    private func persist(_ chats: [SavedChat]) -> Bool {
        guard !isReadOnly else {
            errorMessage = errorMessage ?? "Saved chats are read-only."
            return false
        }
        if let failure = writeFailureForTesting {
            errorMessage = "Chats couldn't be saved. \(failure)"
            return false
        }
        guard let fileURL else {
            errorMessage = nil
            return true
        }
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
