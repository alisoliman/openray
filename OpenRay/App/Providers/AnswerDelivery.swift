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

    /// Settings › General › Primary Action: ↩ pastes when the person chose Paste, ⌘↩ then copies.
    @MainActor static func current(in model: LauncherModel) -> AnswerPrimaryAction {
        model.store.database.preferences.primaryActionPastes ? .paste : .copy
    }
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

/// Slice 3 rows that hold the selection only provisionally, so an arriving answer or result
/// isn't stranded below them. `LauncherModel.synchronizeSelection` asks this.
///
/// * A words-only calculator answer is never the default selection while search results are
///   still arriving (`CalculatorProvider.pendingWordAnswerID`); the default is the best title
///   match already present, else the next row.
/// * While a words-only answer is on screen, or while one of these rows holds the selection
///   (the answer, or Translate's language rows during a translation), a selection the person
///   hasn't moved follows the default, so a file, app or translation arriving above takes it.
/// * Once the person moves the selection, nothing moves it again until the query changes.
enum ProvisionalSelection {
    static let ids: Set<String> = [
        CalculatorProvider.wordAnswerID, CalculatorProvider.pendingWordAnswerID, "translation.target",
        "translation.source",
    ]

    static func isProvisional(_ id: String?) -> Bool { id.map(ids.contains) ?? false }

    /// Rows that are never the default selection.
    static func isNeverDefault(_ id: String) -> Bool { id == CalculatorProvider.pendingWordAnswerID }

    /// The default selection: the first row that may be a default, else the first row.
    static func defaultID(in items: [LauncherItem]) -> String? {
        (items.first { !isNeverDefault($0.id) } ?? items.first)?.id
    }

    /// Whether an untouched selection should follow the default for these rows.
    static func followsDefault(selectedID: String?, items: [LauncherItem]) -> Bool {
        isProvisional(selectedID) || items.contains { CalculatorProvider.isWordAnswer($0.id) }
    }
}
