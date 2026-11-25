import Foundation

/// Which commands can hold an alias or a global hotkey. Commands that can be invoked
/// safely without picking an item qualify. Writing commands use the text selected in
/// the app you came from, so they need no input either.
///
/// This is a registry query: the twenty commands that were bindable before the registry,
/// plus whatever a registered provider accepts (`CommandProviderRegistration`). It is
/// nonisolated and needs no provider instance, because the library asks while decoding.
enum CuratedCommand {
    /// The commands bindable before the registry, in the order Settings lists them. Some are
    /// now served by providers; they keep their place and their stored bindings.
    static let targetIDs = [
        "section.clipboard", "section.applications", "section.files", "section.snippets",
        "section.quicklinks", "section.notes", "section.calculator", "section.windows",
        "ai.chat", "ai.summarize", "ai.rewrite", "ai.proofread", "ai.shorten", "ai.actionItems",
        "settings", "window.leftHalf", "window.rightHalf", "window.maximize",
        "window.center", "window.restore",
    ]

    /// The registrations bindings are checked against. Always `CommandProviders.all` in the app;
    /// tests bind extra registrations with `CuratedCommand.$registrations.withValue(…)`.
    @TaskLocal static var registrations: [CommandProviderRegistration] = CommandProviders.all

    static func supports(_ targetID: String) -> Bool {
        supports(targetID, registrations: registrations)
    }

    static func supports(_ targetID: String, registrations: [CommandProviderRegistration]) -> Bool {
        targetIDs.contains(targetID) || registrations.contains { $0.acceptsBinding(targetID) }
    }
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
