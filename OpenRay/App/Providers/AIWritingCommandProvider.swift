import Foundation

/// The built-in writing commands (Summarize Text, Improve Writing, …), served through the
/// command registry. Ask AI itself stays a built-in row; these run on the text selected in
/// the app you came from.
@MainActor
final class AIWritingCommandProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(
        id: "ai.writing", bindableIDs: writingActions.map(commandID(for:))
    ) { AIWritingCommandProvider() }

    nonisolated static let writingActions = AIAction.allCases.filter { $0 != .chat }

    /// `ai.summarize` and so on: the ids favorites, usage and bindings already store.
    nonisolated static func commandID(for action: AIAction) -> String { "ai.\(action.id)" }

    var id: String { Self.registration.id }
    var title: String { "AI Writing" }

    init() {}

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        let available = model.ai.availability.isAvailable
        return Self.writingActions.map { action in
            CommandDescriptor(
                id: Self.commandID(for: action), title: action.title,
                subtitle: available ? LauncherModel.aiCommandSubtitle : "Not available yet",
                kind: .ai, symbol: action.kindSymbol, keywords: ["AI", "writing", "text", action.subtitle],
                mode: .ai, badge: "AI command",
                // Found by what it does (“…meeting notes”), the row says that instead of the
                // generic line. An unavailable command keeps saying so.
                detail: available ? action.subtitle : nil,
                isUnavailable: !available)
        }
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        guard let action = Self.writingActions.first(where: { Self.commandID(for: $0) == ref.id }) else { return }
        model.store.recordUse(of: item.id)
        model.openAI(action)
    }
}
