import Foundation

struct QuickNote: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var modifiedAt: Date = .now

    static func derivedTitle(from content: String) -> String {
        let line =
            content.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    var wordCount: Int {
        content.split { $0.isWhitespace || $0.isNewline }.count
    }
}
