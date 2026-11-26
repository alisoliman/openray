import AppKit
import SwiftUI

/// Reports the natural height of list content, so the panel can size itself.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func reportsContentHeight() -> some View {
        background {
            GeometryReader { proxy in Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height) }
        }
    }
}

struct ResultsList: View {
    @Bindable var model: LauncherModel
    var groups: [LauncherResultGroup]
    var selectedID: String?
    var tall: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    notices
                    ForEach(groups) { group in
                        if let title = group.title {
                            SectionHeader(title: title, trailing: group.trailing, loading: group.isLoading)
                        }
                        groupBody(group)
                    }
                    footnote
                }
                .padding(.horizontal, OR.Metric.listInset)
                .padding(.top, 6).padding(.bottom, 10)
                .reportsContentHeight()
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.selectedID) { scrollToSelection(proxy) }
            .onAppear {
                // An editor, AI or onboarding replaces the list, so it's rebuilt at the top when
                // they close. Wait a turn for the lazy stack's layout, then bring the selection back.
                Task { @MainActor in scrollToSelection(proxy, anchor: .center) }
            }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, anchor: UnitPoint? = nil) {
        guard let selectedID = model.selectedID,
            let group = groups.first(where: { $0.items.contains { $0.id == selectedID } })
        else { return }
        proxy.scrollTo(Self.rowID(group: group.id, item: selectedID), anchor: anchor)
    }

    /// Rows are identified within their group. An item moves between groups as
    /// you type (Favorites, Top Hit, Commands, Recent), and an identity shared
    /// across groups let a lazily cached row keep a stale selection fill.
    static func rowID(group: String, item: String) -> String { "\(group)/\(item)" }

    @ViewBuilder private func groupBody(_ group: LauncherResultGroup) -> some View {
        switch group.style {
        case .favorites:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                // The strip is exactly `favoriteItems`, in order, so its position is the ⌘-number.
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    FavoriteTile(
                        model: model, item: item, selected: item.id == selectedID, number: index < 8 ? index + 1 : nil
                    )
                    .id(Self.rowID(group: group.id, item: item.id))
                }
            }
            .padding(.top, 2).padding(.bottom, 6)
        case .grid:
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 6), count: LauncherModel.columns(for: group) ?? 4),
                spacing: 6
            ) {
                ForEach(group.items) { item in
                    if let tile = group.tile {
                        ProvidedGridTile(model: model, item: item, selected: item.id == selectedID, renderer: tile)
                            .id(Self.rowID(group: group.id, item: item.id))
                    } else {
                        WindowTile(model: model, item: item, selected: item.id == selectedID)
                            .id(Self.rowID(group: group.id, item: item.id))
                    }
                }
            }
            .padding(.vertical, 4)
        case .calculator:
            ForEach(group.items) { item in
                if let calculation = item.calculatorAnswer(in: model) {
                    CalculatorCard(model: model, item: item, calculation: calculation, selected: item.id == selectedID)
                        .id(Self.rowID(group: group.id, item: item.id)).padding(.top, 2).padding(.bottom, 6)
                }
            }
        case .list, .fallback:
            ForEach(group.items) { item in
                ResultRow(model: model, item: item, selected: item.id == selectedID, tall: tall)
                    .id(Self.rowID(group: group.id, item: item.id))
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if model.section == .home, model.argumentLink == nil {
            HomeNotices(model: model)
        }
        if model.section == .clipboard {
            ClipboardNotices(model: model).padding(.top, 4)
        }
        if model.section == .windows, !model.accessibilityAllowed {
            InlineNotice(.error, symbol: "checkmark.shield", title: "Window layouts need Accessibility.", detail: "Nothing else does.") {
                Button("Enable…") {
                    model.windows.requestPermission()
                    SystemSettingsLink.open(.accessibility)
                }
                .buttonStyle(.orSecondary)
            }
            .padding(.top, 4).padding(.bottom, 6)
        }
        if model.section == .home, let issue = Calculator.searchIssue(for: model.query) {
            SectionHeader(title: "Calculator")
            CalculatorErrorCard(issue: issue).padding(.top, 2).padding(.bottom, 6)
        }
    }

    @ViewBuilder private var footnote: some View {
        if model.section == .files, !groups.isEmpty {
            Label("Hidden folders, Library and build products are skipped.", systemImage: "info.circle")
                .labelStyle(TightLabelStyle())
                .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                .padding(.horizontal, 10).padding(.top, 14)
        }
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String? = nil
    var loading = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(OR.Font.sectionHeader).foregroundStyle(OR.Color.text2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if loading { Spinner(size: 12, lineWidth: 1.5) }
            if let trailing {
                Text(trailing).font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text2)
            }
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 5)
    }
}

// MARK: - Rows

struct ResultRow: View {
    let model: LauncherModel
    let item: LauncherItem
    var selected: Bool
    var tall = false
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedID = item.id
            model.perform(item)
        } label: {
            HStack(spacing: 10) {
                ItemGlyph(item: item, size: 24, dimmed: unavailable)
                if tall {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        subtitle
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title.layoutPriority(1)
                        subtitle
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                accessories
            }
            .padding(.horizontal, 10)
            .frame(height: tall ? OR.Metric.tallRow : OR.Metric.row)
            .background(fill, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
            .contentShape(.rect(cornerRadius: OR.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(item.subtitle)
        .accessibilityHint(
            spokenHint(model.spokenActionTitle(for: item), model.spokenAliasChip(for: item), rowShortcut?.spoken))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("result.\(item.id)")
        .contextMenu { ActionContextMenu(model: model, item: item) }
    }

    private var fill: Color { selected ? OR.Color.fill2 : hovering ? OR.Color.fill1 : .clear }

    /// Search results mark favorites; Everything's Favorites strip already says so.
    private var showsStar: Bool { model.isFavorite(item) && (model.section != .home || !model.query.isEmpty) }

    /// Clipboard groups pinned entries itself, so the pin only shows elsewhere.
    private var showsPin: Bool {
        if case .clipboard(let entry) = item.action { return entry.isPinned && model.section != .clipboard }
        return false
    }

    /// The description, then the star and pin, which are hidden glyphs.
    private var spokenLabel: String {
        let parts: [String?] = [item.accessibilityDescription, showsStar ? "Favorite" : nil, showsPin ? "Pinned" : nil]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }

    /// The row's keycaps: a retarget ⌘-number, the bound shortcut, or Tab for Ask AI.
    private var rowShortcut: KeyShortcut? {
        if let number = model.numberShortcut(for: item) { return .command("\(number)") }
        if let shortcut = model.boundShortcut(for: item) { return KeyShortcut(shortcut) }
        return item.id == "fallback.ai" ? .tab : nil
    }

    /// Retarget rows show their keyword instead; the primary argument row keeps the browser name.
    private var showsKindLabel: Bool {
        if item.id == "fallback.ai" { return false }
        if let link = model.argumentLink, item.id.hasPrefix("argument."), item.id != "argument.\(link.id)" {
            return false
        }
        return true
    }

    private var unavailable: Bool {
        if case .window = item.action { return !model.accessibilityAllowed }
        if case .ai(let action) = item.action, action != .chat { return !model.ai.availability.isAvailable }
        if case .provided(let ref) = item.action { return ref.has(.unavailable) }
        return false
    }

    private var title: some View {
        HighlightedText(text: item.title, query: highlightQuery, font: tall && isMonospacedSnippet ? OR.Font.mono : OR.Font.rowTitle)
            .foregroundStyle(unavailable ? OR.Color.text2 : OR.Color.text)
            .lineLimit(1)
    }

    @ViewBuilder private var subtitle: some View {
        if !item.subtitle.isEmpty {
            HStack(spacing: 4) {
                if unavailable, case .window = item.action {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        .foregroundStyle(OR.Color.warning)
                }
                Text(item.subtitle).font(OR.Font.body)
            }
            // Paths keep their last folders, which is what tells same-named files apart.
            .foregroundStyle(OR.Color.text2).lineLimit(1).truncationMode(isFile ? .middle : .tail)
        }
    }

    private var isFile: Bool {
        if case .file = item.action { return true }
        return false
    }

    private var isMonospacedSnippet: Bool {
        if case .clipboard(let entry) = item.action, let text = entry.plainText {
            return text.contains("let ") || text.contains("func ") || text.contains("{") && text.contains("}")
        }
        return false
    }

    private var highlightQuery: String {
        model.section == .home && model.argumentLink == nil || [.applications, .snippets, .notes, .quicklinks, .files]
            .contains(model.section)
            ? model.query : ""
    }

    @ViewBuilder private var accessories: some View {
        HStack(spacing: 8) {
            // The row's VoiceOver label says Favorite and Pinned.
            if showsStar {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(OR.Color.warning)
                    .accessibilityHidden(true)
            }
            if showsPin {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(OR.Color.text2)
                    .accessibilityHidden(true)
            }
            if let alias = model.aliasChip(for: item) { AliasChip(text: alias) }
            if let shortcut = rowShortcut { KeyCaps(shortcut) }
            if tall {
                if case .note(let note) = item.action {
                    Text(Self.age(of: note.modifiedAt)).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                }
            } else if showsKindLabel {
                Text(accessoryLabel).font(OR.Font.callout).foregroundStyle(OR.Color.text2).lineLimit(1)
            }
        }
        .fixedSize()
    }

    /// A compact age: now, 4m, 2h, 3d, then a date.
    static func age(of date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var accessoryLabel: String {
        switch item.action {
        case .ai(let action): return action == .chat ? "AI" : "AI command"
        case .clipboard(let entry): return entry.kindTitle
        default: return item.badge
        }
    }
}

/// The leading 24 pt glyph: a real app or file icon, a clipboard thumbnail, or a kind tile.
struct ItemGlyph: View {
    let item: LauncherItem
    var size: CGFloat = 24
    var dimmed = false

    var body: some View {
        Group {
            if let image = item.clipboardImage {
                ClipboardImageView(resource: image, maxPixelSize: Int(size * 3), showsFailureText: false, fills: true)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .strokeBorder(.black.opacity(0.2), lineWidth: 0.5)
                    }
            } else if let url = item.iconURL {
                WorkspaceIcon(url: url, size: size)
            } else {
                KindTile(kind: item.kind, symbol: tileSymbol, size: size, dimmed: dimmed)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var tileSymbol: String {
        switch item.action {
        case .window: "rectangle.split.2x1"
        default: item.symbol
        }
    }
}

/// Bolds the characters a query matched.
struct HighlightedText: View {
    var text: String
    var query: String
    var font: Font
    var matchFont = Font(NSFont.systemFont(ofSize: 13, weight: .bold))

    var body: some View {
        Text(attributed).font(font)
    }

    private var attributed: AttributedString {
        var string = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return string }
        let offsets = SearchMatcher.matchedOffsets(trimmed, in: text)
        guard !offsets.isEmpty else { return string }
        var index = string.startIndex
        var offset = 0
        while index < string.endIndex {
            let next = string.characters.index(after: index)
            if offsets.contains(offset) {
                string[index..<next].font = matchFont
            }
            index = next
            offset += 1
        }
        return string
    }
}

// MARK: - Favorites strip

struct FavoriteTile: View {
    let model: LauncherModel
    let item: LauncherItem
    var selected: Bool
    /// ⌘1–⌘8 for the first eight tiles, from the tile's position in the strip.
    let number: Int?
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedID = item.id
            model.perform(item)
        } label: {
            VStack(spacing: 7) {
                ItemGlyph(item: item, size: 32)
                Text(shortTitle).font(.system(size: 11.5, weight: .medium)).foregroundStyle(OR.Color.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(number.map { "⌘\($0)" } ?? " ")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(OR.Color.text2)
            }
            .padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 9)
            .frame(maxWidth: .infinity)
            .background(
                selected ? OR.Color.fill2 : hovering ? OR.Color.fill1 : .clear,
                in: .rect(cornerRadius: OR.Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: OR.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(item.title), Favorite")
        .accessibilityHint(
            spokenHint(model.spokenActionTitle(for: item), model.spokenAliasChip(for: item), shortcut?.spoken))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("result.\(item.id)")
        .contextMenu { ActionContextMenu(model: model, item: item) }
    }
}

extension FavoriteTile {
    fileprivate var shortTitle: String {
        if case .section(let section) = item.action { return section.shortTitle }
        return item.title
    }

    /// The tile's ⌘-number, or the favorite's bound shortcut when it has none.
    fileprivate var shortcut: KeyShortcut? {
        if let number { return .command("\(number)") }
        return model.boundShortcut(for: item).map { KeyShortcut($0) }
    }
}

// MARK: - Windows grid

struct WindowTile: View {
    let model: LauncherModel
    let item: LauncherItem
    var selected: Bool
    /// Reserved only when some layout has a shortcut, so rows stay aligned.
    var showsShortcutRow: Bool {
        model.windowItems.contains { model.boundShortcut(for: $0) != nil }
    }
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedID = item.id
            model.perform(item)
        } label: {
            VStack(spacing: 7) {
                if case .window(let layout) = item.action {
                    MiniScreen(layout: layout).opacity(model.accessibilityAllowed ? 1 : 0.5)
                }
                Text(item.title).font(OR.Font.calloutEmphasis)
                    .foregroundStyle(model.accessibilityAllowed ? OR.Color.text : OR.Color.text2)
                if showsShortcutRow {
                    HStack(spacing: 2) {
                        if let shortcut = model.boundShortcut(for: item) {
                            KeyCaps(KeyShortcut(shortcut), size: .small)
                        }
                    }
                    .frame(minHeight: 18)
                }
            }
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(
                selected ? OR.Color.fill2 : hovering ? OR.Color.fill1 : .clear,
                in: .rect(cornerRadius: OR.Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: OR.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityHint(
            spokenHint(
                model.spokenActionTitle(for: item), model.spokenAliasChip(for: item),
                model.boundShortcut(for: item).map { KeyShortcut($0).spoken }))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("result.\(item.id)")
        .contextMenu { ActionContextMenu(model: model, item: item) }
    }
}

/// A picture of the layout on a small screen.
struct MiniScreen: View {
    var layout: WindowLayout

    var body: some View {
        let screen = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack(alignment: .topLeading) {
            screen.fill(OR.Color.fill2)
            screen.strokeBorder(OR.Color.separator)
            GeometryReader { proxy in
                let inner = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 3, dy: 3)
                let frame = rect(in: inner)
                if layout == .nextDisplay {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(OR.Color.separator)
                            .background(OR.Color.fill2, in: .rect(cornerRadius: 4, style: .continuous))
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Kind.window.linearGradient)
                    }
                    .padding(5)
                } else if layout == .restore {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(OR.Color.text2, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Kind.window.linearGradient)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(width: 92, height: 58)
        .accessibilityHidden(true)
    }

    private func rect(in r: CGRect) -> CGRect {
        let gap: CGFloat = 1.5
        let halfW = r.width / 2 - gap
        let halfH = r.height / 2 - gap
        switch layout {
        case .leftHalf: return CGRect(x: r.minX, y: r.minY, width: halfW, height: r.height)
        case .rightHalf: return CGRect(x: r.midX + gap, y: r.minY, width: halfW, height: r.height)
        case .topHalf: return CGRect(x: r.minX, y: r.minY, width: r.width, height: halfH)
        case .bottomHalf: return CGRect(x: r.minX, y: r.midY + gap, width: r.width, height: halfH)
        case .topLeft: return CGRect(x: r.minX, y: r.minY, width: halfW, height: halfH)
        case .topRight: return CGRect(x: r.midX + gap, y: r.minY, width: halfW, height: halfH)
        case .bottomLeft: return CGRect(x: r.minX, y: r.midY + gap, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: r.midX + gap, y: r.midY + gap, width: halfW, height: halfH)
        case .maximize, .nextDisplay: return r
        case .center: return r.insetBy(dx: r.width * 0.22, dy: r.height * 0.18)
        case .restore: return CGRect(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.12, width: r.width * 0.56, height: r.height * 0.62)
        }
    }
}

// MARK: - Calculator

struct CalculatorCard: View {
    let model: LauncherModel
    /// The row the card stands for: clicking performs it, as ↩ does.
    var item: LauncherItem
    let calculation: Calculation
    var selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                side(
                    value: calculation.conversion.map { "\($0.source.value) \($0.source.symbol)" } ?? calculation.expression,
                    unit: calculation.conversion?.source.name ?? calculation.inputLabel ?? "Expression", emphasized: false)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OR.Color.text2)
                    .frame(width: 28, height: 28).background(OR.Color.fill2, in: .circle)
                side(
                    value: calculation.result,
                    unit: calculation.conversion?.target.name ?? calculation.resultLabel ?? "Result", emphasized: true)
            }
            if let source = sourceNote {
                Text(source).font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, 10)
            }
            if let conversion = calculation.conversion, !conversion.related.isEmpty {
                Hairline().padding(.top, 14)
                HStack(spacing: 6) {
                    ForEach(conversion.related, id: \.symbol) { quantity in
                        Button {
                            copy(quantity)
                        } label: {
                            Text(label(quantity))
                                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .foregroundStyle(OR.Color.text2)
                                .padding(.horizontal, 9).frame(height: 24)
                                .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(label(quantity))")
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(OR.Color.fill2, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: OR.Radius.card, style: .continuous)
                    .strokeBorder(OR.Color.separator, lineWidth: 1)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            model.selectedID = item.id
            model.perform(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(calculation.expression) equals \(calculation.result)")
        .accessibilityHint("\(model.primaryTitle(for: item)): \(calculation.value)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("result.calculation")
        // Combining hides the chips, so each related unit is also an action.
        .accessibilityActions {
            if let conversion = calculation.conversion {
                ForEach(conversion.related, id: \.symbol) { quantity in
                    Button("Copy \(label(quantity))") { copy(quantity) }
                }
            }
        }
    }

    /// Where a currency answer's rate comes from, or a date's day: the calculation's detail,
    /// without the trailing key hint. Plain arithmetic and unit conversions need none.
    private var sourceNote: String? {
        guard [.currency, .date, .duration, .time].contains(calculation.kind) else { return nil }
        let parts = calculation.detail.components(separatedBy: " · ").filter { !$0.hasPrefix("Return to") }
        let note = parts.filter { $0 != "Currency" }.joined(separator: " · ")
        return note.isEmpty ? nil : note
    }

    private func label(_ quantity: Calculation.Quantity) -> String { "\(quantity.value) \(quantity.symbol)" }

    /// Copies the precise, ungrouped number, like Return does for the result. The toast
    /// quotes what was copied, not the rounded chip.
    private func copy(_ quantity: Calculation.Quantity) {
        model.copy(quantity.copyValue)
    }

    private func side(value: String, unit: String, emphasized: Bool) -> some View {
        VStack(spacing: 4) {
            Text(value).font(emphasized ? OR.Font.result : OR.Font.resultInput)
                .tracking(-0.4)
                .foregroundStyle(OR.Color.text)
                .lineLimit(1).minimumScaleFactor(0.5)
                .textSelection(.enabled)
            Text(unit).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CalculatorErrorCard: View {
    var issue: Calculator.Issue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 17, weight: .medium))
                .foregroundStyle(OR.Color.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(OR.Font.headline).foregroundStyle(OR.Color.text)
                Text(issue.message).font(OR.Font.body).foregroundStyle(OR.Color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(OR.Color.dangerSoft, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Clipboard notices

struct ClipboardNotices: View {
    let model: LauncherModel

    var body: some View {
        VStack(spacing: 6) {
            if model.store.database.clipboardIsPaused {
                InlineNotice(
                    .warning, symbol: "pause.fill", title: "Capture is paused.",
                    detail: model.store.database.clipboard.isEmpty ? nil : "Saved history is still here."
                ) {
                    Button("Resume") { model.setClipboardCapture(true) }.buttonStyle(.orSecondary)
                }
            }
            if let note = model.clipboard.accessMessage {
                InlineNotice(.info, symbol: "hand.raised", title: note) {
                    Button("Fix…") { model.openSettings(.permissions) }.buttonStyle(.orSecondary)
                }
            }
            // Only background capture failures land here; copy failures go to the action bar.
            if let note = model.clipboard.contentMessage {
                InlineNotice(.warning, symbol: "exclamationmark.triangle", title: note) {
                    Button("Dismiss") { model.clipboard.clearContentMessage() }.buttonStyle(.orSecondary)
                }
            }
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Home notices

/// A launcher shortcut that couldn't register, with the way to fix it.
struct HomeNotices: View {
    let model: LauncherModel

    var body: some View {
        if let error = model.shortcutError {
            InlineNotice(.warning, symbol: "keyboard", title: "Launcher shortcut is inactive.", detail: error) {
                Button("Change Shortcut…") { model.openSettings(.shortcuts) }.buttonStyle(.orSecondary)
            }
            .padding(.top, 4).padding(.bottom, 6)
        }
    }
}

// MARK: - VoiceOver

extension LauncherModel {
    /// What Return does, without a Launch Services lookup per row; the action bar and ⌘K name the app.
    fileprivate func spokenActionTitle(for item: LauncherItem) -> String {
        // Layouts say “Enable Accessibility” until it's allowed, which needs no lookup.
        if case .window = item.action { return primaryTitle(for: item) }
        return item.primaryActionTitle
    }

    /// The row's alias or keyword chip, in words.
    fileprivate func spokenAliasChip(for item: LauncherItem) -> String? {
        guard let alias = aliasChip(for: item) else { return nil }
        switch item.action {
        case .snippet, .quicklink: return "Keyword \(alias)"
        default: return "Alias \(alias)"
        }
    }
}

/// Joins the parts of a VoiceOver hint that apply, one sentence each.
private func spokenHint(_ parts: String?...) -> String {
    parts.compactMap { $0 }.joined(separator: ". ")
}
