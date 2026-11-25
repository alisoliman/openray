import Foundation

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var keyword: String
    var content: String
    /// Per-snippet keyword expansion. Missing means on, subject to the master switch.
    var expandsKeyword: Bool? = nil

    var expandsAsYouType: Bool { expandsKeyword ?? true }

    func expanded(at date: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone
        dateFormatter.dateStyle = .medium
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        timeFormatter.timeStyle = .short
        return
            content
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
    }

    func validate(against others: [Snippet]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryValidationError("Give this snippet a name.")
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.count <= 32_000 else {
            throw LibraryValidationError("Snippet text must contain between 1 and 32,000 characters.")
        }
        if !keyword.isEmpty {
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789;:/._-")
            guard (2...32).contains(keyword.count), keyword.unicodeScalars.allSatisfy(allowed.contains) else {
                throw LibraryValidationError("Use a 2–32 character keyword without spaces, such as ;email.")
            }
            guard !others.contains(where: { $0.id != id && $0.keyword == keyword }) else {
                throw LibraryValidationError("Another snippet already uses this keyword.")
            }
        }
    }
}
