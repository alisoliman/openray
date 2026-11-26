import Testing

@testable import OpenRay

struct GridSelectionTests {
    /// Two sections, four columns: rows [0–3] [4–7] [8–9] in the first, [0–2] in the second.
    private func grid(wraps: Bool = true, pageRows: Int = 2) -> GridSelection {
        GridSelection(sectionSizes: [10, 3], columns: 4, wraps: wraps, pageRows: pageRows)
    }

    private func at(_ section: Int, _ item: Int, wraps: Bool = true) -> GridSelection {
        var selection = grid(wraps: wraps)
        selection.select(GridPosition(section: section, item: item))
        return selection
    }

    private func after(_ moves: [GridMove], from section: Int, _ item: Int, wraps: Bool = true) -> GridPosition? {
        var selection = at(section, item, wraps: wraps)
        for move in moves { selection.move(move) }
        return selection.position
    }

    @Test func startsOnTheFirstCell() {
        #expect(grid().position == GridPosition(section: 0, item: 0))
        #expect(GridSelection(sectionSizes: [0, 0, 3], columns: 4).position == GridPosition(section: 2, item: 0))
        #expect(GridSelection(sectionSizes: [], columns: 4).position == nil)
        #expect(GridSelection(sectionSizes: [0], columns: 4).isEmpty)
    }

    @Test func rowsSplitEachSection() {
        #expect(grid().rows.map(\.count) == [4, 4, 2, 3])
        #expect(grid().rows.map(\.section) == [0, 0, 0, 1])
    }

    @Test(arguments: [
        (GridMove.right, 0, 3, 0, 4), (.right, 0, 9, 1, 0), (.right, 1, 2, 0, 0),
        (.left, 0, 4, 0, 3), (.left, 1, 0, 0, 9), (.left, 0, 0, 1, 2),
        (.down, 0, 1, 0, 5), (.down, 0, 5, 0, 9), (.down, 0, 7, 0, 9), (.down, 0, 9, 1, 1), (.down, 1, 1, 0, 1),
        (.up, 0, 5, 0, 1), (.up, 1, 2, 0, 9), (.up, 0, 2, 1, 2), (.up, 0, 3, 1, 2),
        (.first, 1, 2, 0, 0), (.last, 0, 0, 1, 2),
        (.nextSection, 0, 5, 1, 0), (.nextSection, 1, 1, 0, 0),
        (.previousSection, 1, 2, 1, 0), (.previousSection, 1, 0, 0, 0), (.previousSection, 0, 0, 1, 0),
    ])
    func movesWithWrapping(move: GridMove, section: Int, item: Int, toSection: Int, toItem: Int) {
        #expect(after([move], from: section, item) == GridPosition(section: toSection, item: toItem))
    }

    @Test(arguments: [
        (GridMove.right, 1, 2), (.left, 0, 0), (.down, 1, 1), (.up, 0, 2), (.nextSection, 1, 0),
        (.previousSection, 0, 0),
    ])
    func stopsAtTheEdgesWithoutWrapping(move: GridMove, section: Int, item: Int) {
        #expect(after([move], from: section, item, wraps: false) == GridPosition(section: section, item: item))
    }

    @Test func pagesMoveByRowsAndStopAtTheEnds() {
        #expect(after([.pageDown], from: 0, 1) == GridPosition(section: 0, item: 9))
        #expect(after([.pageDown, .pageDown], from: 0, 1) == GridPosition(section: 1, item: 1))
        #expect(after([.pageDown, .pageDown, .pageDown], from: 0, 1) == GridPosition(section: 1, item: 1))
        #expect(after([.pageUp], from: 1, 2) == GridPosition(section: 0, item: 6))
        #expect(after([.pageUp, .pageUp], from: 1, 2) == GridPosition(section: 0, item: 2))
    }

    @Test func emptySectionsAreSkipped() {
        var selection = GridSelection(sectionSizes: [2, 0, 2], columns: 4)
        selection.move(.right)
        selection.move(.right)
        #expect(selection.position == GridPosition(section: 2, item: 0))
        selection.move(.up)
        #expect(selection.position == GridPosition(section: 0, item: 0))
        selection.move(.nextSection)
        #expect(selection.position == GridPosition(section: 2, item: 0))
    }

    @Test func reloadKeepsOrClampsTheSelection() {
        var selection = at(0, 9)
        selection.reload(sectionSizes: [12, 3])
        #expect(selection.position == GridPosition(section: 0, item: 9))
        selection.reload(sectionSizes: [5, 3])
        #expect(selection.position == GridPosition(section: 0, item: 4))
        selection.reload(sectionSizes: [0, 3])
        #expect(selection.position == GridPosition(section: 1, item: 0))
        selection.reload(sectionSizes: [4, 0])
        #expect(selection.position == GridPosition(section: 0, item: 3))
        selection.reload(sectionSizes: [])
        #expect(selection.position == nil)
        selection.reload(sectionSizes: [3])
        #expect(selection.position == GridPosition(section: 0, item: 0))
    }

    @Test func columnChangesKeepTheCell() {
        var selection = at(0, 6)
        selection.setColumns(8)
        #expect(selection.position == GridPosition(section: 0, item: 6))
        selection.move(.down)
        #expect(selection.position == GridPosition(section: 0, item: 9))
        selection.reload(sectionSizes: [10, 3], columns: 2)
        selection.move(.up)
        #expect(selection.position == GridPosition(section: 0, item: 7))
    }

    @Test func selectClampsOutOfRangeCells() {
        var selection = grid()
        selection.select(GridPosition(section: 5, item: 50))
        #expect(selection.position == GridPosition(section: 1, item: 2))
        selection.select(GridPosition(section: -1, item: -4))
        #expect(selection.position == GridPosition(section: 0, item: 0))
        selection.select(nil)
        #expect(selection.position == nil)
        selection.move(.down)
        #expect(selection.position == GridPosition(section: 0, item: 0))
    }

    @Test func columnCountsStayBetweenSixAndTen() {
        #expect(GridColumns.clamped(3) == 6)
        #expect(GridColumns.clamped(12) == 10)
        #expect(GridColumns.zoomedIn(6) == 6)
        #expect(GridColumns.zoomedIn(8) == 7)
        #expect(GridColumns.zoomedOut(10) == 10)
        #expect(GridColumns.zoomedOut(8) == 9)
        #expect(GridColumns.range.contains(GridColumns.defaultCount))
    }

    @Test func glyphsShrinkAsColumnsGrow() {
        #expect(GridGlyph.size(columns: 6) == 34)
        #expect(GridGlyph.size(columns: 10) == 22)
        #expect(GridGlyph.size(columns: 20) == 22)
    }

    private struct Cell: Identifiable {
        var id: String
    }

    @Test func cellIDsAreScopedToTheirSection() {
        #expect(GridView<Cell, GridGlyph>.cellID(section: "pinned", item: "🔥") == "pinned/🔥")
    }
}
