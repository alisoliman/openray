import SwiftUI

/// ⌘K: a searchable action panel. Its own field takes the keyboard while it's
/// open, so arrows and Return act on actions, never on the results behind it.
struct ActionPanel: View {
    @Bindable var model: LauncherModel
    @State private var focus = 0

    var body: some View {
        let entries = model.filteredActionEntries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OR.Color.text2)
                LauncherSearchInput(
                    text: $model.actionFilter,
                    placeholder: model.actionPath.last.map { "Search \($0.title)" } ?? "Search actions",
                    focusRequest: focus,
                    submit: model.performActionSelection, move: model.moveActionSelection,
                    // Esc closes the top layer, which is ⌘/ when it's open over this panel.
                    cancel: model.goBack, paste: model.performCommandReturnAction,
                    moveHorizontally: model.moveActionSelectionHorizontally, tertiary: model.performTertiary,
                    fontSize: 13, accessibilityLabel: "Search actions", identifier: "actions.search")
            }
            .padding(.horizontal, 14).frame(height: 38)
            .overlay(alignment: .bottom) { Hairline() }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let parent = model.actionPath.last {
                            ActionPanelBreadcrumb(title: parent.title) { model.closeActionSubmenu() }
                            Hairline().padding(.vertical, 2).padding(.horizontal, 2)
                        }
                        if entries.isEmpty {
                            Text("No matching actions").font(OR.Font.body).foregroundStyle(OR.Color.text2)
                                .frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0, entries[index - 1].group != entry.group {
                                Hairline().padding(.vertical, 4).padding(.horizontal, 2)
                            }
                            // A titled section starts where the title changes.
                            if let section = entry.section, index == 0 || entries[index - 1].section != section {
                                ActionPanelSectionHeader(title: section)
                            }
                            row(entry, selected: index == model.actionSelection).id(entry.id)
                        }
                    }
                    .padding(6)
                    .reportsActionPanelHeight()
                }
                .onChange(of: model.actionSelection) {
                    if entries.indices.contains(model.actionSelection) {
                        proxy.scrollTo(entries[model.actionSelection].id)
                    }
                }
            }
        }
        .frame(width: 344)
        .popoverSurface()
        .onAppear { focus += 1 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private func row(_ entry: ActionEntry, selected: Bool) -> some View {
        Button {
            model.performAction(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(entry.isDestructive ? OR.Color.danger : OR.Color.text2)
                    .frame(width: 18)
                Text(entry.title).font(OR.Font.body)
                    .foregroundStyle(entry.isDestructive ? OR.Color.danger : OR.Color.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut = entry.shortcut { KeyCaps(shortcut, size: .small) }
                if !entry.children.isEmpty {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OR.Color.text2)
                }
            }
            .padding(.leading, 8).padding(.trailing, 6).frame(height: 32)
            .background(selected ? OR.Color.fill2 : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0, let index = model.filteredActionEntries.firstIndex(where: { $0.id == entry.id }) { model.actionSelection = index } }
        .accessibilityLabel(entry.title)
        .accessibilityHint(entry.children.isEmpty ? entry.shortcut?.spoken ?? "" : "Opens \(entry.children.count) more actions")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("action.\(entry.id)")
    }
}

struct ActionPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func reportsActionPanelHeight() -> some View {
        background {
            GeometryReader { proxy in Color.clear.preference(key: ActionPanelHeightKey.self, value: proxy.size.height) }
        }
    }
}

/// The right-click menu offers the same actions as ⌘K.
struct ActionContextMenu: View {
    let model: LauncherModel
    let item: LauncherItem

    var body: some View {
        let entries = model.actions(for: item).filter { $0.group != .panel }
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0, entries[index - 1].group != entry.group { Divider() }
            ActionMenuEntry(model: model, item: item, entry: entry)
        }
    }
}

/// One entry in a menu: a button, or a submenu with its own entries, to any depth.
struct ActionMenuEntry: View {
    let model: LauncherModel
    let item: LauncherItem
    let entry: ActionEntry

    var body: some View {
        if entry.children.isEmpty {
            Button(role: entry.isDestructive ? .destructive : nil) {
                model.selectedID = item.id
                entry.perform()
            } label: {
                Label(entry.title, systemImage: entry.symbol)
            }
        } else {
            Menu {
                ForEach(entry.children) { child in
                    AnyView(ActionMenuEntry(model: model, item: item, entry: child))
                }
            } label: {
                Label(entry.title, systemImage: entry.symbol)
            }
        }
    }
}

/// Hidden buttons that make every listed action shortcut work without opening ⌘K.
struct ActionShortcutButtons: View {
    let entries: [ActionEntry]

    /// The bindable entries for the selection the root view resolved. Pass nil
    /// when no row is showing, so keys never act on a hidden selection.
    static func entries(for model: LauncherModel, selected: LauncherItem?) -> [ActionEntry] {
        guard !model.showActions, model.confirmation == nil else { return [] }
        return model.actions(for: selected).filter { $0.key != nil }
    }

    var body: some View {
        ZStack {
            ForEach(entries) { entry in
                Button(entry.title) { entry.perform() }
                    .keyboardShortcut(entry.key!, modifiers: entry.modifiers)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}

// MARK: - Shortcuts overlay

/// ⌘/: only what applies here, then a short Everywhere list. Shortcuts keep
/// working while it's open, so it's a reference you can act from.
struct ShortcutsOverlay: View {
    let model: LauncherModel
    /// The selection the root view resolved, or nil when no row is acted on.
    let selected: LauncherItem?

    var body: some View {
        let local = localRows
        ZStack {
            Color.black.opacity(0.18)
                .onTapGesture { model.showShortcuts = false }
            VStack(alignment: .leading, spacing: 0) {
                Text("Shortcuts in \(scopeTitle)").font(OR.Font.headline).foregroundStyle(OR.Color.text)
                Text("Press any shortcut to use it, or esc to close.").font(OR.Font.callout)
                    .foregroundStyle(OR.Color.text2).padding(.top, 4)
                if !local.isEmpty { columns(local).padding(.top, 10) }
                Text("Everywhere").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(OR.Color.text2)
                    .padding(.top, 12).padding(.bottom, 2)
                columns(everywhereRows)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            .frame(width: 560)
            .popoverSurface()
        }
        .overlay(alignment: .bottom) { bar }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard shortcuts")
    }

    /// The overlay's own bar, above the dim layer. It still shows toasts and
    /// confirmations, because shortcuts keep working underneath.
    private var bar: some View {
        ActionBar(
            feedback: model.feedback, confirmation: model.confirmation, confirmationInstance: model.confirmationInstanceID,
            context: { Text("Shortcuts").font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text) },
            actions: {
                ActionBarButton(title: "Close", keys: ["esc"], style: .ghost, isOn: true) { model.showShortcuts = false }
            },
            onCancelConfirmation: { model.confirmation = nil },
            onConfirm: { if let confirmation = model.confirmation { model.confirm(confirmation) } },
            onConfirmationShown: model.confirmationDidAppear, onApprove: model.approveConfirmation,
            announces: false)
        .contentShape(.rect)
    }

    private var scopeTitle: String {
        if model.editor != nil { return "the Editor" }
        if model.destination == .ai { return model.ai.action.title }
        return model.section == .home ? "Everything" : model.section.title
    }

    private func columns(_ rows: [(String, [String])]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible())], spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).font(.system(size: 12.5)).foregroundStyle(OR.Color.text)
                    Spacer()
                    KeyCaps(row.1, size: .small)
                }
                .frame(height: 28)
                .overlay(alignment: .bottom) { Hairline() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.0), \(KeyShortcut(row.1).spoken)")
            }
        }
    }

    /// Rows name commands, so they use Title Case, as ⌘K and macOS menus do.
    var localRows: [(String, [String])] {
        if model.editor != nil {
            return [("Save", ["⌘", "S"]), ("Cancel or Done", ["esc"]), ("Next Field", ["Tab"])]
        }
        if model.destination == .ai { return aiRows }
        if model.showsClipboardOptIn { return [("Turn On", ["↩"]), ("Not Now", ["esc"])] }
        var rows: [(String, [String])] = []
        if let item = selected, !model.returnIsInert(for: item) {
            rows.append((model.primaryTitle(for: item), ["↩"]))
        }
        if let item = selected {
            if let secondary = model.secondaryTitle(for: item) { rows.append((secondary, ["⌘", "↩"])) }
        }
        let tab = tabRow
        switch model.section {
        case .home:
            if let tab { rows.append(tab) }
            rows.append(("Open Favorite", ["⌘", "1–8"]))
        case .clipboard:
            // Named as ⌘K names it: by what pressing it shows next.
            rows += [("Show \(model.clipboardFilter.next.title)", ["⌘", "P"]), ("Pin to Top", ["⇧", "⌘", "P"])]
            if let tab { rows.append(tab) }
            rows.append(("Delete Entry", ["⌘", "⌫"]))
        case .snippets, .quicklinks, .notes:
            rows += [("New \(model.section.itemNoun.capitalized)", ["⌘", "N"]), ("Edit", ["⌘", "E"]), ("Delete", ["⌘", "⌫"])]
        case .files:
            rows += [("Quick Look", ["⌘", "Y"]), ("Reveal in Finder", ["⇧", "⌘", "R"]), ("Copy Path", ["⇧", "⌘", "C"])]
        case .applications:
            rows += [("Reveal in Finder", ["⇧", "⌘", "R"]), ("Copy Path", ["⇧", "⌘", "C"])]
        case .windows:
            rows += [("Move Between Layouts", ["←", "→", "↑", "↓"])]
        case .calculator, .provided:
            break
        }
        if model.section != .home, model.section != .clipboard, let tab { rows.append(tab) }
        if let item = selected, item.canFavorite {
            rows.append((model.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites", ["⇧", "⌘", "F"]))
        }
        return rows
    }

    /// What Tab does for the selection, following LauncherModel.handleTab.
    private var tabRow: (String, [String])? {
        guard model.argumentLink == nil else { return nil }
        if model.argumentSession != nil { return ("Next Argument", ["Tab"]) }
        if let selected, !model.argumentSpecs(for: selected).isEmpty { return ("Enter Arguments", ["Tab"]) }
        switch selected?.action {
        case .section(let target)? where model.section == .home && !model.query.isEmpty:
            return ("Open \(target.title)", ["Tab"])
        case .provided(let ref)? where model.section == .home && !model.query.isEmpty:
            // A provider's list opens with Tab, as a built-in scope does.
            if case .view(let scope)? = model.registry.descriptor(for: ref, in: model)?.mode {
                return ("Open \(scope.title)", ["Tab"])
            }
            return ("Ask AI", ["Tab"])
        case .quicklink(let link, let argument)? where link.needsQuery && argument.isEmpty:
            return ("Enter Search Term", ["Tab"])
        case .clipboard(let entry)?:
            return entry.plainText == nil ? nil : ("Ask AI About This", ["Tab"])
        default:
            // Outside Home, Tab asks AI only about a typed query.
            return model.section == .home || !model.isQueryBlank ? ("Ask AI", ["Tab"]) : nil
        }
    }

    /// Mirrors the AI action bar. In chat ↩ sends and ⌘↩ and ⇧↩ add a line in the composer; a
    /// writing run's rows come from `LauncherModel.aiWritingShortcutRows` (↩ pastes, ⌘↩ copies).
    /// While a response is being written, Stop is the only command that runs.
    private var aiRows: [(String, [String])] {
        let ai = model.ai
        guard ai.availability.isAvailable else { return [] }
        var rows: [(String, [String])] = []
        let newLine: [(String, [String])] = [("New Line", ["⇧", "↩"]), ("New Line", ["⌘", "↩"])]
        if ai.action == .chat {
            // The composer still takes text while a reply is written.
            if !ai.isGenerating { rows.append(("Send", ["↩"])) }
            rows += newLine
            if !ai.attachments.isEmpty { rows.append(("Remove Attachment", ["⌫"])) }
            if ai.isGenerating { return rows + [("Stop", ["⌘", "."])] }
            if !ai.messages.isEmpty { rows.append(("New Chat", ["⌘", "N"])) }
            if ai.canRetry { rows.append(("Try Again", ["⌘", "R"])) }
            if ai.latestResponse != nil { rows.append(("Save as Note", ["⌘", "S"])) }
            return rows
        }
        return model.aiWritingShortcutRows
    }

    var everywhereRows: [(String, [String])] {
        // The editor turns off ⌘K and the favorite numbers, and esc closes it.
        if model.editor != nil { return [("Settings", ["⌘", ","])] }
        let leave: (String, [String]) =
            model.destination == .ai
            ? ("Leave AI", ["esc"]) : model.section == .home ? ("Clear Search", ["esc"]) : ("Leave Scope", ["⌫"])
        var rows = [("Actions", ["⌘", "K"]), leave]
        rows.append(("Favorites", ["⌘", "1–8"]))
        if model.destination == .search {
            rows.append(("Jump Between Sections", ["⌘", "↑", "↓"]))
            rows.append(("Back to Everything", ["⌘", "esc"]))
        }
        // main #12: Back that works whatever Esc is set to do.
        rows.append(("Go Back", ["⌘", "["]))
        rows.append(("Close Window", ["⌘", "W"]))
        rows.append(("Settings", ["⌘", ","]))
        return rows
    }
}
