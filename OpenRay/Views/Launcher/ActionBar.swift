import SwiftUI

/// The bottom bar. The left side shows context or a toast; the right side
/// always names what ↩ and ⌘↩ do. Confirmations happen here too.
struct ActionBar<Context: View, Actions: View>: View {
    var feedback: Feedback?
    var confirmation: ActionConfirmation?
    /// The model's `confirmationInstanceID`. A bar that doesn't pass it can't approve a prompt
    /// that loses something, because the instance it reports never matches.
    var confirmationInstance: String? = nil
    @ViewBuilder var context: Context
    @ViewBuilder var actions: Actions
    var onCancelConfirmation: () -> Void = {}
    var onConfirm: () -> Void = {}
    /// Reports the prompt this bar is showing, once it's drawn and not covered. Prompts that need
    /// visible approval can be approved only after this.
    var onConfirmationShown: ((String) -> Void)? = nil
    /// The approve button, with the id of the prompt it showed; replaces `onConfirm` when set.
    var onApprove: ((String) -> Void)? = nil
    /// False for a bar drawn over another one, so VoiceOver hears each toast once.
    var announces = true
    @Environment(\.actionBarIsCovered) private var isCovered

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let confirmation {
                    HStack(spacing: 8) {
                        Image(systemName: confirmation.symbol).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OR.Color.danger).accessibilityHidden(true)
                        Text("\(Text(confirmation.question).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)) \(Text(confirmation.detail).foregroundStyle(OR.Color.text2))")
                            .lineLimit(1)
                    }
                    .transition(.opacity)
                    // A covered bar reports nothing until it's uncovered. The report starts the
                    // prompt's exposure; the model waits out its fade-in and the panel's reveal.
                    .onAppear { reportShown(confirmation) }
                    .onChange(of: "\(confirmationInstance ?? confirmation.id)/\(isCovered)") { reportShown(confirmation) }
                } else if let feedback {
                    ToastLabel(feedback: feedback).transition(.opacity)
                } else {
                    HStack(spacing: 8) { context }
                        .foregroundStyle(OR.Color.text2)
                        .transition(.opacity)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(OR.Motion.quick, value: feedback?.id)
            .animation(OR.Motion.quick, value: confirmation?.id)
            // A confirmation is shown over a toast, so it's announced first. A bar that
            // appears with one, as bar mode expands for a toast, announces it as it appears.
            .announce(
                announces ? (confirmation.map { "\($0.question) \($0.detail)" } ?? feedback?.text) : nil, initial: true)

            if let confirmation {
                ActionBarButton(title: "Cancel", keys: ["esc"], style: .ghost, action: onCancelConfirmation)
                ActionBarButton(
                    title: confirmation.confirmTitle, keys: ["↩"], style: confirmation.isDestructive ? .danger : .accent
                ) {
                    if let onApprove { onApprove(confirmationInstance ?? confirmation.id) } else { onConfirm() }
                }
            } else {
                actions
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: OR.Metric.actionBar)
        // Moves as one piece while the panel resizes, so its items never split across baselines.
        .geometryGroup()
        .overlay(alignment: .top) { Hairline() }
        // Opacity 0 also hides it from VoiceOver. accessibilityHidden(false) would
        // re-expose every symbol inside that is hidden on purpose.
        .opacity(isCovered ? 0 : 1)
        .animation(OR.Motion.quick, value: isCovered)
        .allowsHitTesting(!isCovered)
    }
}

extension ActionBar {
    fileprivate func reportShown(_ confirmation: ActionConfirmation) {
        guard !isCovered else { return }
        onConfirmationShown?(confirmationInstance ?? confirmation.id)
    }
}

extension EnvironmentValues {
    /// True while the ⌘/ overlay draws its own bar over the panel's action bar.
    @Entry var actionBarIsCovered = false
}

struct ToastLabel: View {
    var feedback: Feedback

    var body: some View {
        HStack(spacing: 7) {
            if feedback.style == .working {
                Spinner(size: 14, lineWidth: 1.75)
            } else {
                Image(systemName: feedback.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(feedback.text).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
                .truncationMode(.tail)
        }
        .help(feedback.text)
    }

    private var tint: Color {
        switch feedback.style {
        case .success: OR.Color.success
        case .info: OR.Color.info
        case .warning: OR.Color.warning
        case .error: OR.Color.danger
        case .working: OR.Color.text2
        }
    }
}

struct ActionBarButton: View {
    enum Style { case primary, ghost, accent, danger }
    var title: String
    var keys: [String]
    var style: Style = .primary
    var isOn = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).lineLimit(1)
                // The confirm cap is clear and takes the button's color, as in the design system.
                KeyCaps(keys, style: style == .accent ? .onAccent : style == .danger ? .plain : .standard)
                    .foregroundStyle(style == .accent ? OR.Color.onAccent : style == .danger ? OR.Color.danger : OR.Color.text2)
            }
            .font(style == .ghost ? .system(size: 12, weight: .medium) : OR.Font.calloutEmphasis)
            .foregroundStyle(foreground)
            .padding(.leading, 9).padding(.trailing, 6)
            .frame(height: 30)
            .background(background, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
            .contentShape(.rect(cornerRadius: OR.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityHint(KeyShortcut(keys).spoken)
    }

    private var foreground: Color {
        switch style {
        case .primary: OR.Color.text
        case .ghost: OR.Color.text2
        case .accent: OR.Color.onAccent
        case .danger: OR.Color.danger
        }
    }

    private var background: Color {
        switch style {
        case .accent: OR.Color.accentButton
        case .danger: OR.Color.dangerSoft
        default: isOn ? OR.Color.fill2 : hovering ? OR.Color.fill1 : .clear
        }
    }
}

struct ActionBarDivider: View {
    var body: some View {
        Rectangle().fill(OR.Color.separator).frame(width: 1, height: 16).padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

struct ContextDot: View {
    var body: some View {
        Circle().fill(OR.Color.text3).frame(width: 3, height: 3).accessibilityHidden(true)
    }
}

/// The lock glyph that stands in for the privacy story, details one hover away.
struct OnThisMacLabel: View {
    var text = "On this Mac"
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            Text(text)
        }
        .help("OpenRay keeps your library, clipboard history and AI conversations on this Mac. No account, analytics or cloud sync.")
        .accessibilityElement(children: .combine)
    }
}

/// The action bar for search and scopes.
struct SearchActionBar: View {
    @Bindable var model: LauncherModel
    var selected: LauncherItem?
    var resultCount: Int
    /// A source such as Files is still streaming, so “No matches” would be premature.
    var isSearching = false

    var body: some View {
        ActionBar(
            feedback: model.feedback ?? storeFeedback, confirmation: model.confirmation, confirmationInstance: model.confirmationInstanceID,
            context: { context },
            actions: { actions },
            onCancelConfirmation: { model.confirmation = nil },
            onConfirm: { if let confirmation = model.confirmation { model.confirm(confirmation) } },
            onConfirmationShown: model.confirmationDidAppear, onApprove: model.approveConfirmation)
    }

    /// The read-only library error stays here. An inactive launcher shortcut is a Home notice instead.
    private var storeFeedback: Feedback? {
        model.store.errorMessage.map { .error($0) }
    }

    @ViewBuilder private var context: some View {
        if model.showActions, let item = selected {
            Text(item.title).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
        } else if let link = model.argumentLink {
            KindTile(kind: .quicklink, symbol: "link", size: 18)
            Text(link.name).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
            ContextDot()
            Text("⌫ to edit the keyword")
        } else if model.section == .home, selected?.id == "calculation" {
            KindTile(kind: .calculator, size: 18)
            Text("Calculator").font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
        } else if model.section == .home {
            ORMark(size: 18)
            Text("Everything").font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
            ContextDot()
            if model.isQueryBlank {
                OnThisMacLabel(text: model.clipboard.usesGeneralPasteboard ? "On this Mac" : "Verification build")
            } else if resultCount == 0 {
                Text(isSearching ? "Searching…" : "No matches")
            } else {
                Text("\(resultCount.formatted()) result\(resultCount == 1 ? "" : "s")")
            }
        } else {
            KindTile(kind: model.section.kind, symbol: model.section.tileSymbol, size: 18)
            Text(model.section.title).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
            ContextDot()
            scopeStatus
        }
    }

    @ViewBuilder private var scopeStatus: some View {
        switch model.section {
        case .clipboard:
            let preferences = model.store.database.preferences
            let count = model.store.database.clipboard.count
            // With a query, the count is what the list shows, as in every other scope.
            if !model.isQueryBlank {
                Text(resultCount == 0 ? "No matches" : "\(resultCount.formatted()) result\(resultCount == 1 ? "" : "s")")
                ContextDot()
            } else if count > 0 {
                Text("\(count.formatted()) item\(count == 1 ? "" : "s")")
                ContextDot()
            }
            if preferences.clipboardEnabled {
                if model.clipboard.accessBehavior == .alwaysDeny {
                    StatusLabel(tone: .danger, text: "Blocked by macOS", tintsText: false)
                } else {
                    StatusLabel(tone: .success, text: "Capturing", tintsText: false)
                }
            } else if model.store.database.clipboardIsPaused {
                StatusLabel(tone: .warning, text: "Paused", tintsText: false)
            } else {
                StatusLabel(tone: .neutral, text: "Off", tintsText: false)
            }
        case .windows:
            Text("←→↑↓ to move")
        case .calculator:
            Text("Arithmetic and conversions")
        default:
            Text(Self.countStatus(resultCount: resultCount, isSearching: isSearching, isQueryBlank: model.isQueryBlank))
        }
    }

    /// A scope's count. A pending search outranks it, so an empty scope that's still loading
    /// never says “0 items”.
    static func countStatus(resultCount: Int, isSearching: Bool, isQueryBlank: Bool) -> String {
        if resultCount == 0, isSearching { return "Searching…" }
        let noun = isQueryBlank ? "item" : "result"
        return "\(resultCount.formatted()) \(noun)\(resultCount == 1 ? "" : "s")"
    }

    /// While ⌘K is open, the bar names only the item and the open Actions button.
    @ViewBuilder private var actions: some View {
        if model.showActions {
            EmptyView()
        } else if let item = selected, model.returnIsInert(for: item) {
            // A quicklink token with no term yet: nothing to run, and New isn't the next step.
            EmptyView()
        } else if let item = selected {
            ActionBarButton(title: model.primaryTitle(for: item), keys: ["↩"]) { model.perform(item) }
            if let secondary = model.secondaryTitle(for: item) {
                ActionBarButton(title: secondary, keys: ["⌘", "↩"], style: .ghost) {
                    model.selectedID = item.id
                    model.pasteSelected()
                }
            }
            ActionBarDivider()
        } else if model.section.createsItems {
            ActionBarButton(title: "New \(model.section.itemNoun.capitalized)", keys: ["⌘", "N"]) { model.createItem() }
            ActionBarDivider()
        }
        ActionBarButton(title: "Actions", keys: ["⌘", "K"], style: .ghost, isOn: model.showActions) {
            model.showActions.toggle()
        }
        .accessibilityIdentifier("launcher.actions")
    }
}
