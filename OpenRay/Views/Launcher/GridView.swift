import SwiftUI

// MARK: - Selection model

/// A cell in a sectioned grid.
struct GridPosition: Hashable, Sendable {
    var section: Int
    var item: Int
}

enum GridMove: Equatable, Sendable {
    case left, right, up, down
    /// A page of `GridSelection.pageRows` rows.
    case pageUp, pageDown
    case first, last
    /// The first cell of the next or previous section (⌘↓ / ⌘↑).
    case nextSection, previousSection
}

/// Column counts for dense grids: 6 to 10, changed with ⌘- and ⌘+ and reset with ⌘0.
enum GridColumns {
    static let range = 6...10
    static let defaultCount = 8

    static func clamped(_ count: Int) -> Int { min(max(count, range.lowerBound), range.upperBound) }

    /// ⌘+ makes cells larger, so there are fewer columns.
    static func zoomedIn(_ count: Int) -> Int { clamped(count - 1) }
    static func zoomedOut(_ count: Int) -> Int { clamped(count + 1) }
}

/// Keyboard selection in a grid of sections laid out in rows of `columns` cells.
/// Pure and value-typed, so every move is unit-tested without a view.
///
/// * ← and → move through cells in reading order, across rows and sections.
/// * ↑ and ↓ move a row, keeping the column; a shorter row lands on its last cell.
/// * With `wraps`, moving past either end continues from the other.
/// * Page moves go `pageRows` rows and stop at the first or last row.
struct GridSelection: Equatable, Sendable {
    private(set) var sectionSizes: [Int]
    private(set) var columns: Int
    var wraps: Bool
    var pageRows: Int
    private(set) var position: GridPosition?

    init(sectionSizes: [Int], columns: Int, wraps: Bool = true, pageRows: Int = 4) {
        self.sectionSizes = sectionSizes.map { max(0, $0) }
        self.columns = max(1, columns)
        self.wraps = wraps
        self.pageRows = max(1, pageRows)
        position = nil
        position = cells.first
    }

    var isEmpty: Bool { sectionSizes.allSatisfy { $0 == 0 } }

    /// Selects a cell, or the nearest valid one.
    mutating func select(_ position: GridPosition?) {
        guard let position else {
            self.position = nil
            return
        }
        self.position = clamped(position)
    }

    /// New contents keep the selected cell when it still exists, else the nearest one.
    mutating func reload(sectionSizes: [Int], columns: Int? = nil) {
        self.sectionSizes = sectionSizes.map { max(0, $0) }
        if let columns { self.columns = max(1, columns) }
        position = position.flatMap(clamped) ?? cells.first
    }

    mutating func setColumns(_ columns: Int) {
        self.columns = max(1, columns)
    }

    mutating func move(_ move: GridMove) {
        let rows = self.rows
        guard !rows.isEmpty else {
            position = nil
            return
        }
        guard let position, let current = row(containing: position, in: rows) else {
            self.position = cells.first
            return
        }
        let column = position.item - rows[current].start
        switch move {
        case .right, .left:
            let cells = self.cells
            guard let index = cells.firstIndex(of: position) else { return }
            var target = index + (move == .right ? 1 : -1)
            if !cells.indices.contains(target) {
                guard wraps else { return }
                target = (target + cells.count) % cells.count
            }
            self.position = cells[target]
        case .down, .up:
            var target = current + (move == .down ? 1 : -1)
            if !rows.indices.contains(target) {
                guard wraps else { return }
                target = (target + rows.count) % rows.count
            }
            self.position = cell(in: rows[target], column: column)
        case .pageDown:
            self.position = cell(in: rows[min(current + pageRows, rows.count - 1)], column: column)
        case .pageUp:
            self.position = cell(in: rows[max(current - pageRows, 0)], column: column)
        case .first:
            self.position = cells.first
        case .last:
            self.position = cells.last
        case .nextSection, .previousSection:
            let filled = sectionSizes.indices.filter { sectionSizes[$0] > 0 }
            guard let index = filled.firstIndex(of: position.section) else { return }
            var target = index + (move == .nextSection ? 1 : -1)
            if move == .previousSection, position.item > 0 { target = index }
            if !filled.indices.contains(target) {
                guard wraps else { return }
                target = (target + filled.count) % filled.count
            }
            self.position = GridPosition(section: filled[target], item: 0)
        }
    }

    // MARK: Layout

    struct Row: Equatable {
        var section: Int
        var start: Int
        var count: Int
    }

    var rows: [Row] {
        sectionSizes.enumerated().flatMap { section, size in
            stride(from: 0, to: size, by: columns).map { start in
                Row(section: section, start: start, count: min(columns, size - start))
            }
        }
    }

    private var cells: [GridPosition] {
        sectionSizes.enumerated().flatMap { section, size in
            (0..<size).map { GridPosition(section: section, item: $0) }
        }
    }

    private func row(containing position: GridPosition, in rows: [Row]) -> Int? {
        rows.firstIndex { $0.section == position.section && (($0.start)..<($0.start + $0.count)).contains(position.item) }
    }

    private func cell(in row: Row, column: Int) -> GridPosition {
        GridPosition(section: row.section, item: row.start + min(column, row.count - 1))
    }

    private func clamped(_ position: GridPosition) -> GridPosition? {
        guard !isEmpty else { return nil }
        let section = min(max(position.section, 0), sectionSizes.count - 1)
        if sectionSizes[section] > 0 {
            return GridPosition(section: section, item: min(max(position.item, 0), sectionSizes[section] - 1))
        }
        // An emptied section hands the selection to the next section with cells, else the previous.
        if let next = sectionSizes.indices.first(where: { $0 > section && sectionSizes[$0] > 0 }) {
            return GridPosition(section: next, item: 0)
        }
        if let previous = sectionSizes.indices.last(where: { $0 < section && sectionSizes[$0] > 0 }) {
            return GridPosition(section: previous, item: sectionSizes[previous] - 1)
        }
        return nil
    }
}

// MARK: - View

struct GridSection<Item: Identifiable>: Identifiable {
    var id: String
    var title: String?
    var trailing: String? = nil
    var items: [Item]
}

struct GridCellState: Equatable, Sendable {
    var selected: Bool
    var hovered: Bool
}

/// A dense, sectioned grid in the OpenRay design system: section headers, square
/// tiles, a fill for the selection and a lighter one on hover. It draws a
/// `GridSelection` but doesn't take focus or keys; the launcher routes arrow keys
/// into the selection, as it does for the list.
struct GridView<Item: Identifiable, Cell: View>: View {
    var sections: [GridSection<Item>]
    var columns: Int
    var selection: GridPosition?
    var spacing: CGFloat = 4
    var accessibilityLabel: (Item) -> String
    var onActivate: (GridPosition, Item) -> Void
    @ViewBuilder var cell: (Item, GridCellState) -> Cell

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        if let title = section.title {
                            SectionHeader(title: title, trailing: section.trailing)
                        }
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, columns)),
                            spacing: spacing
                        ) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                                let position = GridPosition(section: sectionIndex, item: itemIndex)
                                GridTile(
                                    selected: position == selection, label: accessibilityLabel(item),
                                    action: { onActivate(position, item) }
                                ) { state in
                                    cell(item, state)
                                }
                                .id(Self.cellID(section: section.id, item: item.id))
                            }
                        }
                        .padding(.bottom, 6)
                    }
                }
                .padding(.horizontal, OR.Metric.listInset)
                .padding(.bottom, OR.Space.s2)
            }
            .scrollIndicators(.automatic)
            .onChange(of: selection) { scroll(proxy) }
        }
    }

    /// Cells are identified within their section, because Pinned and Frequently Used
    /// repeat items from the categories below.
    nonisolated static func cellID(section: String, item: Item.ID) -> String { "\(section)/\(item)" }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let selection, sections.indices.contains(selection.section),
            sections[selection.section].items.indices.contains(selection.item)
        else { return }
        let section = sections[selection.section]
        proxy.scrollTo(Self.cellID(section: section.id, item: section.items[selection.item].id))
    }
}

/// One square cell with the grid's selected and hover fills.
struct GridTile<Content: View>: View {
    var selected: Bool
    var label: String
    var action: () -> Void
    @ViewBuilder var content: (GridCellState) -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content(GridCellState(selected: selected, hovered: hovering))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(
                    selected ? OR.Color.fill2 : hovering ? OR.Color.fill1 : .clear,
                    in: .rect(cornerRadius: OR.Radius.row, style: .continuous)
                )
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous)
                            .strokeBorder(OR.Color.separator, lineWidth: 1)
                    }
                }
                .contentShape(.rect(cornerRadius: OR.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A large glyph for emoji and symbol cells. Text symbols use the primary text color.
struct GridGlyph: View {
    var glyph: String
    var columns: Int

    var body: some View {
        Text(glyph)
            .font(.system(size: Self.size(columns: columns)))
            .foregroundStyle(OR.Color.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityHidden(true)
    }

    /// Fewer columns, larger glyphs: 34 pt at 6 columns down to 22 pt at 10.
    nonisolated static func size(columns: Int) -> CGFloat {
        CGFloat(34 - (GridColumns.clamped(columns) - GridColumns.range.lowerBound) * 3)
    }
}
