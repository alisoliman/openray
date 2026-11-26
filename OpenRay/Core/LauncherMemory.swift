import Foundation
import Observation

/// What the launcher learns from use: which row you pick for a query, and the searches you
/// ran. Kept in its own file beside the library (`launcher-memory.json`), so it never needs a
/// schema change and Reset Ranking can't touch library data.
struct LauncherMemory: Codable, Equatable, Sendable {
    /// Normalized query → item id → times picked.
    var picks: [String: [String: Int]] = [:]
    /// Searches, newest first.
    var history: [String] = []

    static let historyLimit = 50
    static let queryLimit = 300
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Case, accents and spacing don't make a query new.
    static func normalize(_ query: String) -> String {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func pickCount(of itemID: String, for query: String) -> Int {
        picks[Self.normalize(query)]?[itemID] ?? 0
    }

    /// Whether anything was learned about a row.
    func hasLearned(_ itemID: String) -> Bool {
        picks.values.contains { $0[itemID] != nil }
    }

    mutating func recordPick(of itemID: String, for query: String) {
        let key = Self.normalize(query)
        guard !key.isEmpty, key.count <= 200 else { return }
        var counts = picks[key] ?? [:]
        counts[itemID] = min((counts[itemID] ?? 0) + 1, 1_000)
        picks[key] = counts
        // The oldest-learned queries can't be told apart from rare ones, so trim the smallest.
        if picks.count > Self.queryLimit {
            let smallest = picks.min { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }?.key
            if let smallest { picks.removeValue(forKey: smallest) }
        }
    }

    mutating func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return }
        history.removeAll { Self.normalize($0) == Self.normalize(trimmed) }
        history.insert(trimmed, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    /// Forgets what was learned about one row, or about every row when `itemID` is nil.
    mutating func resetRanking(of itemID: String? = nil) {
        guard let itemID else {
            picks = [:]
            return
        }
        for key in picks.keys {
            picks[key]?.removeValue(forKey: itemID)
            if picks[key]?.isEmpty == true { picks.removeValue(forKey: key) }
        }
    }
}

/// Loads and saves `LauncherMemory`. Without a file URL (tests, the verification build) it
/// lives in memory only. A file that can't be read starts fresh; it holds nothing irreplaceable.
@MainActor
@Observable
final class LauncherMemoryStore {
    private(set) var memory: LauncherMemory
    let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(LauncherMemory.self, from: data)
        {
            memory = decoded
        } else {
            memory = LauncherMemory()
        }
    }

    /// The memory file beside a library file.
    static func fileURL(besideLibrary libraryURL: URL?) -> URL? {
        libraryURL?.deletingLastPathComponent().appending(path: "launcher-memory.json")
    }

    func update(_ change: (inout LauncherMemory) -> Void) {
        var next = memory
        change(&next)
        guard next != memory else { return }
        memory = next
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(next).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Ranking is a convenience: a failed write keeps it for this session only.
        }
    }
}
