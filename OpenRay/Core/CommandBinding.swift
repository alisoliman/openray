import Foundation

/// Commands that can be invoked safely without an item or additional input.
enum CuratedCommand {
    static let targetIDs = [
        "section.clipboard", "section.applications", "section.files", "section.snippets",
        "section.quicklinks", "section.notes", "section.calculator", "section.windows",
        "ai.chat", "settings", "window.leftHalf", "window.rightHalf", "window.maximize",
        "window.center", "window.restore",
    ]

    static func supports(_ targetID: String) -> Bool { targetIDs.contains(targetID) }
}

struct CommandBinding: Codable, Equatable, Identifiable, Sendable {
    var targetID: String
    var alias: String? = nil
    var shortcut: CommandShortcut? = nil

    var id: String { targetID }
    var isEmpty: Bool { Self.normalizedAlias(alias) == nil && shortcut == nil }

    static func normalizedAlias(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? nil : trimmed.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    func validate() throws {
        guard CuratedCommand.supports(targetID) else {
            throw LibraryValidationError("This command does not support an alias or global hotkey.")
        }
        if let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            guard alias.count <= 32, !alias.contains(where: \.isWhitespace) else {
                throw LibraryValidationError("Use an alias of up to 32 characters without spaces.")
            }
        }
        try shortcut?.validate()
    }
}
