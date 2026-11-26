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
        case .provided(let confirmation): "provided.\(confirmation.id).\(confirmation.token.uuidString)"
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

    /// Danger-styled, and approved by Return only while the prompt is on screen. The built-in
    /// prompts all lose something; a provider's says so with `isDestructive`.
    var isDestructive: Bool {
        switch self {
        case .delete, .discardChanges, .clearClipboardHistory: true
        case .provided(let confirmation): confirmation.isDestructive
        }
    }

    /// Every question that loses something (Delete, Discard Changes, Clear Clipboard History, a
    /// provider's Shut Down or Empty Trash) can be approved only after this very prompt instance
    /// was shown on a visible surface for `LauncherModel.minimumPromptExposure`, and only by a
    /// fresh key press or its own button.
    var requiresVisibleApproval: Bool { isDestructive }

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
