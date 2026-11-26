import Foundation

/// What the left side of the action bar says. Toasts hold for 2.4 s and then
/// the context returns; errors stay until the selection changes.
struct Feedback: Identifiable, Equatable {
    enum Style: Equatable { case success, info, warning, error, working }
    let id = UUID()
    var style: Style
    var text: String

    static func success(_ text: String) -> Feedback { Feedback(style: .success, text: text) }
    static func info(_ text: String) -> Feedback { Feedback(style: .info, text: text) }
    static func warning(_ text: String) -> Feedback { Feedback(style: .warning, text: text) }
    static func error(_ text: String) -> Feedback { Feedback(style: .error, text: text) }
    static func working(_ text: String) -> Feedback { Feedback(style: .working, text: text) }

    var expires: Bool { style == .success || style == .info }

    var symbol: String {
        switch style {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning, .error: "exclamationmark.triangle.fill"
        case .working: "hourglass"
        }
    }
}

/// A destructive or lossy step confirmed inside the action bar, so the keyboard
/// never leaves the panel: ↩ confirms and esc cancels.
enum ActionConfirmation: Identifiable {
    case delete(LauncherItem)
    case discardChanges
    /// Delete All removes pinned entries too, so the prompt counts them.
    case clearClipboardHistory(pinnedCount: Int)
    /// A provider's question, such as a command's “Shut down now?”. ↩ runs its `perform`.
    case provided(ProvidedConfirmation)

    var id: String {
        switch self {
        case .delete(let item): "delete.\(item.id)"
        case .discardChanges: "discard"
        case .clearClipboardHistory: "clear"
        case .provided(let confirmation): "provided.\(confirmation.id)"
        }
    }

    var question: String {
        switch self {
        case .delete(let item): "Delete “\(item.title.truncatedForFeedback)”?"
        case .discardChanges: "Discard changes?"
        case .clearClipboardHistory: "Delete all clipboard history?"
        case .provided(let confirmation): confirmation.question
        }
    }

    var detail: String {
        switch self {
        // Notes move to Recently Deleted, where they stay 60 days.
        case .delete(let item) where item.id.hasPrefix("note."): "It moves to Recently Deleted for 60 days."
        case .delete: "You can't undo this."
        case .discardChanges: "Your edits haven't been saved."
        case .clearClipboardHistory(let pinned) where pinned > 0:
            "This also deletes \(pinned) pinned \(pinned == 1 ? "entry" : "entries"). "
                + "Your current clipboard stays as it is."
        case .clearClipboardHistory: "Your current clipboard stays as it is."
        case .provided(let confirmation): confirmation.detail
        }
    }

    var confirmTitle: String {
        switch self {
        case .delete: "Delete"
        case .discardChanges: "Discard"
        case .clearClipboardHistory: "Delete All"
        case .provided(let confirmation): confirmation.confirmTitle
        }
    }

    var symbol: String {
        switch self {
        case .delete, .clearClipboardHistory: "trash"
        case .discardChanges: "arrow.uturn.backward"
        case .provided(let confirmation): confirmation.symbol
        }
    }
}

extension String {
    /// Short enough to quote in the action bar.
    var truncatedForFeedback: String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 42 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
}
