import Foundation

/// How ↩ and ⌘↩ split copying and pasting for Slice 3's answers: calculator results, emoji and
/// symbols, and translations.
///
/// OpenRay's design keeps ↩ = Copy and ⌘↩ = Paste. Slice 1 adds a "Primary action: Copy / Paste"
/// preference; when it lands, `current(in:)` is the one place that reads it. Every Slice 3
/// provider calls `primary` from `perform` and `secondary` from `performSecondary`, and labels
/// its rows with `primaryTitle` and `secondaryTitle`, so nothing else changes.
enum AnswerPrimaryAction: Equatable, Sendable {
    case copy
    case paste

    /// The preference seam. Slice 1: return `.paste` when the person chose Paste.
    @MainActor static func current(in model: LauncherModel) -> AnswerPrimaryAction { .copy }
}

/// Copies or pastes an answer for ↩ and ⌘↩, following `AnswerPrimaryAction`.
@MainActor
enum AnswerDelivery {
    /// ↩'s label: "Copy Emoji", or the paste label when ↩ pastes.
    static func primaryTitle(copy title: String, in model: LauncherModel) -> String {
        AnswerPrimaryAction.current(in: model) == .copy ? title : model.pasteTitle("Paste to")
    }

    /// ⌘↩'s label: the paste label, or "Copy …" when ↩ pastes.
    static func secondaryTitle(copy title: String, for item: LauncherItem, in model: LauncherModel) -> String? {
        AnswerPrimaryAction.current(in: model) == .copy ? model.textPasteTitle(for: item) : title
    }

    /// ↩. Returns false when the copy failed (the model shows why).
    @discardableResult
    static func primary(_ text: String, label: String, in model: LauncherModel) -> Bool {
        deliver(text, label: label, paste: AnswerPrimaryAction.current(in: model) == .paste, in: model)
    }

    /// ⌘↩.
    @discardableResult
    static func secondary(_ text: String, label: String, in model: LauncherModel) -> Bool {
        deliver(text, label: label, paste: AnswerPrimaryAction.current(in: model) == .copy, in: model)
    }

    private static func deliver(_ text: String, label: String, paste: Bool, in model: LauncherModel) -> Bool {
        if paste {
            model.paste(text, label: label)
            return model.feedback?.style != .error
        }
        return model.copy(text, label: label)
    }
}
