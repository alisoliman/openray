import AppKit
import SwiftUI

/// Window geometry: the panel sits at a fixed top edge inside a larger,
/// transparent window so it can grow downward and cast its own shadow.
enum PanelGeometry {
    static let topMargin: CGFloat = 36
    static let sideMargin: CGFloat = 76
    static let bottomMargin: CGFloat = 120
    /// Follows the interface size, so it's read each time the panel is placed.
    static var windowSize: CGSize {
        CGSize(width: OR.Metric.panelWidth + sideMargin * 2, height: OR.Detent.full + topMargin + bottomMargin)
    }
}

struct LauncherRootView: View {
    @Bindable var model: LauncherModel
    @State private var listHeight: CGFloat = 0
    @State private var actionPanelHeight: CGFloat = 0
    /// The drawn height. Only this animates, so content changes stay instant.
    @State private var displayedHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let groups = model.destination == .search && model.editor == nil && model.onboarding == nil ? model.groups : []
        let items = groups.flatMap(\.items)
        let selected = items.first(where: { $0.id == model.selectedID }) ?? items.first
        // Shortcuts never act on a row that the collapsed bar hides.
        let shortcutTarget = model.isCollapsedToBar ? nil : selected
        let targetHeight = panelHeight(groups: groups)
        let height = displayedHeight == 0 ? targetHeight : displayedHeight
        VStack(spacing: 0) {
            PanelSurface {
                content(groups: groups, selected: selected)
                    .environment(\.actionBarIsCovered, model.showShortcuts)
                    .frame(width: panelWidth, height: height, alignment: .top)
                    .overlay(alignment: .bottomTrailing) {
                        ZStack(alignment: .bottomTrailing) {
                            if model.showActions, model.editor == nil {
                                ActionPanel(model: model)
                                    .frame(maxHeight: max(0, min(420, height - 70)))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.trailing, 8).padding(.bottom, OR.Metric.actionBar + 8)
                                    .transition(
                                        reduceMotion
                                            ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
                            }
                        }
                        .animation(OR.Motion.resolve(OR.Motion.standard, reduceMotion: reduceMotion), value: model.showActions)
                    }
                    .overlay {
                        ZStack {
                            if model.showShortcuts {
                                ShortcutsOverlay(model: model, selected: shortcutTarget).transition(.opacity)
                            }
                        }
                        .animation(OR.Motion.resolve(OR.Motion.quick, reduceMotion: reduceMotion), value: model.showShortcuts)
                    }
            }
            .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.98, anchor: .top)
            .opacity(model.isPresented ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.top, PanelGeometry.topMargin)
        .frame(width: PanelGeometry.windowSize.width, height: PanelGeometry.windowSize.height, alignment: .top)
        .animation(OR.Motion.resolve(OR.Motion.panel, reduceMotion: reduceMotion), value: panelWidth)
        .onPreferenceChange(ContentHeightKey.self) { listHeight = $0 }
        .onPreferenceChange(ActionPanelHeightKey.self) { actionPanelHeight = $0 }
        .onChange(of: items.map(\.id), initial: true) { model.synchronizeSelection() }
        .onChange(of: targetHeight, initial: true) { _, newHeight in
            model.panelSize = CGSize(width: panelWidth, height: newHeight)
            // A hidden panel takes its new size at once, so it never grows into view.
            if displayedHeight == 0 || !model.isPresented {
                displayedHeight = newHeight
            } else {
                withAnimation(OR.Motion.resolve(OR.Motion.panel, reduceMotion: reduceMotion)) { displayedHeight = newHeight }
            }
        }
        .onChange(of: panelWidth) { _, width in model.panelSize.width = width }
        .tint(OR.Color.accent)
        .appAppearance(model.store.database.preferences.appearance)
        .background { GlobalShortcutButtons(model: model, selected: shortcutTarget) }
        .environment(\.font, OR.Font.body)
    }

    @ViewBuilder private func content(groups: [LauncherResultGroup], selected: LauncherItem?) -> some View {
        if let step = model.onboarding {
            OnboardingView(model: model, step: step)
        } else if model.editor != nil, let draft = model.draft {
            InlineEditorView(model: model, draft: draft)
        } else if model.destination == .ai {
            AIView(model: model)
        } else {
            VStack(spacing: 0) {
                SearchFieldBar(model: model)
                if !collapsedToBar {
                    Hairline()
                    searchBody(groups: groups, selected: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // The layer above takes the focus; the results recede behind it.
                        .opacity(resultsOpacity)
                        .animation(OR.Motion.resolve(OR.Motion.quick, reduceMotion: reduceMotion), value: resultsOpacity)
                    if !showsClipboardOptIn {
                        SearchActionBar(
                            model: model, selected: selected,
                            resultCount: groups.filter { $0.style != .fallback }.flatMap(\.items).count,
                            isSearching: model.isAwaitingResults || groups.contains(where: \.isLoading))
                    }
                }
            }
        }
    }

    /// .55 under ⌘K and .35 under ⌘/, as in the design's mockups.
    private var resultsOpacity: Double { model.showShortcuts ? 0.35 : model.showActions ? 0.55 : 1 }

    @ViewBuilder private func searchBody(groups: [LauncherResultGroup], selected: LauncherItem?) -> some View {
        if showsClipboardOptIn {
            ClipboardOptInView(model: model)
        } else if groups.allSatisfy({ $0.items.isEmpty && !$0.isLoading }), !hasNotices {
            ScopeEmptyState(model: model).reportsContentHeight()
                .frame(maxHeight: .infinity, alignment: .top)
        } else if model.section.showsPreview, model.argumentLink == nil {
            HStack(spacing: 0) {
                ResultsList(model: model, groups: groups, selectedID: selected?.id, tall: true)
                if let selected { PreviewPane(model: model, item: selected) }
            }
        } else {
            ResultsList(model: model, groups: groups, selectedID: selected?.id, tall: false)
        }
    }

    private var hasNotices: Bool {
        (model.section == .home && (Calculator.searchIssue(for: model.query) != nil || model.shortcutError != nil))
            || (model.section == .clipboard
                && (model.clipboard.accessMessage != nil || model.clipboard.contentMessage != nil
                    || model.store.database.clipboardIsPaused))
    }

    private var showsClipboardOptIn: Bool { model.showsClipboardOptIn }

    /// Bar mode expands whenever there's a query, a toast, a confirmation or an error to show.
    private var collapsedToBar: Bool { model.isCollapsedToBar }

    private var panelWidth: CGFloat { model.onboarding != nil ? OR.Metric.onboardingSize : OR.Metric.panelWidth }

    /// Three detents: bar (60), list (fits content up to 480) and full (560).
    private func panelHeight(groups: [LauncherResultGroup]) -> CGFloat {
        if model.onboarding != nil { return OR.Metric.onboardingSize }
        if model.editor != nil || model.destination == .ai || model.showShortcuts { return OR.Detent.full }
        if collapsedToBar { return OR.Detent.bar }
        if showsClipboardOptIn { return OR.Detent.full }
        let hasItems = groups.contains { !$0.items.isEmpty }
        if model.section.showsPreview, hasItems, model.argumentLink == nil { return OR.Detent.full }
        // The layout grid is three rows of pictures; it needs the full height to show them all.
        if model.section == .windows, hasItems { return OR.Detent.full }
        let chrome = OR.Metric.field + 1 + OR.Metric.actionBar
        var height = min(OR.Detent.list, chrome + (listHeight > 0 ? listHeight : 380))
        height = max(height, chrome + 92)
        if model.showActions {
            height = min(OR.Detent.full, max(height, min(420, actionPanelHeight + 38) + OR.Metric.actionBar + 24))
        }
        return height.rounded()
    }
}

/// Keyboard shortcuts that work anywhere in the panel.
private struct GlobalShortcutButtons: View {
    let model: LauncherModel
    /// The selection LauncherRootView resolved, or nil when shortcuts shouldn't act on a row.
    let selected: LauncherItem?

    var body: some View {
        ZStack {
            if model.onboarding == nil {
                Button("Shortcuts") { model.showShortcuts.toggle() }.keyboardShortcut("/")
                Button("Settings") { model.openSettings() }.keyboardShortcut(",")
                Button("Help") { model.openHelp() }.keyboardShortcut("?", modifiers: [.command, .shift])
                // ⌘K and the item shortcuts stay off while an inline editor is open.
                if model.editor == nil {
                    let entries = ActionShortcutButtons.entries(for: model, selected: selected)
                    // A listed action's ⌘-number wins over the favorite in that position.
                    let claimed = Set(entries.filter { $0.modifiers == .command }.compactMap { $0.key?.character })
                    Button("Actions") { model.showActions.toggle() }.keyboardShortcut("k")
                    Button("New") {
                        if model.destination == .ai {
                            model.ai.newConversation()
                            model.focusRequest += 1
                        } else {
                            model.createItem()
                        }
                    }
                    .keyboardShortcut("n")
                    Button("Cycle Filter") { model.cycleClipboardFilter() }.keyboardShortcut("p")
                    Button("Stop") { model.ai.cancel() }.keyboardShortcut(".")
                    ForEach(1...8, id: \.self) { number in
                        let key = Character("\(number)")
                        if !claimed.contains(key) {
                            Button("Favorite \(number)") { model.performNumber(number) }
                                .keyboardShortcut(KeyEquivalent(key))
                        }
                    }
                    ActionShortcutButtons(entries: entries)
                }
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}
