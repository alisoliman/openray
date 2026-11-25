import CoreGraphics
import Foundation
import Testing

@testable import OpenRay

struct WindowGeometryTests {
    private let laptop = WindowFixture.laptop.visibleFrame
    private let current = CGRect(x: 100, y: 200, width: 600, height: 400)

    /// Where every frame-setting command puts `current` on the laptop, whose
    /// visible frame keeps a 24 pt menu bar and a 76 pt Dock clear.
    private var laptopExpectations: [WindowCommand: CGRect] {
        [
            .leftHalf: CGRect(x: 0, y: 76, width: 720, height: 800),
            .rightHalf: CGRect(x: 720, y: 76, width: 720, height: 800),
            .topHalf: CGRect(x: 0, y: 476, width: 1440, height: 400),
            .bottomHalf: CGRect(x: 0, y: 76, width: 1440, height: 400),
            .centerHalf: CGRect(x: 360, y: 76, width: 720, height: 800),
            .firstThird: CGRect(x: 0, y: 76, width: 480, height: 800),
            .centerThird: CGRect(x: 480, y: 76, width: 480, height: 800),
            .lastThird: CGRect(x: 960, y: 76, width: 480, height: 800),
            .firstTwoThirds: CGRect(x: 0, y: 76, width: 960, height: 800),
            .centerTwoThirds: CGRect(x: 240, y: 76, width: 960, height: 800),
            .lastTwoThirds: CGRect(x: 480, y: 76, width: 960, height: 800),
            .firstFourth: CGRect(x: 0, y: 76, width: 360, height: 800),
            .secondFourth: CGRect(x: 360, y: 76, width: 360, height: 800),
            .thirdFourth: CGRect(x: 720, y: 76, width: 360, height: 800),
            .lastFourth: CGRect(x: 1080, y: 76, width: 360, height: 800),
            .firstThreeFourths: CGRect(x: 0, y: 76, width: 1080, height: 800),
            .lastThreeFourths: CGRect(x: 360, y: 76, width: 1080, height: 800),
            .topLeft: CGRect(x: 0, y: 476, width: 720, height: 400),
            .topRight: CGRect(x: 720, y: 476, width: 720, height: 400),
            .bottomLeft: CGRect(x: 0, y: 76, width: 720, height: 400),
            .bottomRight: CGRect(x: 720, y: 76, width: 720, height: 400),
            .topLeftSixth: CGRect(x: 0, y: 476, width: 480, height: 400),
            .topCenterSixth: CGRect(x: 480, y: 476, width: 480, height: 400),
            .topRightSixth: CGRect(x: 960, y: 476, width: 480, height: 400),
            .bottomLeftSixth: CGRect(x: 0, y: 76, width: 480, height: 400),
            .bottomCenterSixth: CGRect(x: 480, y: 76, width: 480, height: 400),
            .bottomRightSixth: CGRect(x: 960, y: 76, width: 480, height: 400),
            .maximize: CGRect(x: 0, y: 76, width: 1440, height: 800),
            .almostMaximize: CGRect(x: 72, y: 116, width: 1296, height: 720),
            .maximizeHeight: CGRect(x: 100, y: 76, width: 600, height: 800),
            .maximizeWidth: CGRect(x: 0, y: 200, width: 1440, height: 400),
            .reasonableSize: CGRect(x: 288, y: 236, width: 864, height: 480),
            .center: CGRect(x: 420, y: 276, width: 600, height: 400),
            .makeLarger: CGRect(x: 28, y: 160, width: 744, height: 480),
            .makeSmaller: CGRect(x: 172, y: 240, width: 456, height: 320),
            .moveUp: CGRect(x: 100, y: 476, width: 600, height: 400),
            .moveDown: CGRect(x: 100, y: 76, width: 600, height: 400),
            .moveLeft: CGRect(x: 0, y: 200, width: 600, height: 400),
            .moveRight: CGRect(x: 840, y: 200, width: 600, height: 400),
            // `screen` is the target display for display moves: the window keeps its size, centered.
            .nextDisplay: CGRect(x: 420, y: 276, width: 600, height: 400),
            .previousDisplay: CGRect(x: 420, y: 276, width: 600, height: 400),
        ]
    }

    /// Commands that change state rather than compute a frame; WindowManagerCommandTests covers them.
    private let stateCommands: Set<WindowCommand> = [.toggleFullscreen, .minimize, .restore]

    @Test func everyCommandIsCoveredByAGeometryExpectationOrIsAStateCommand() {
        let covered = Set(laptopExpectations.keys).union(stateCommands)
        #expect(covered == Set(WindowCommand.allCases))
        #expect(Set(laptopExpectations.keys).isDisjoint(with: stateCommands))
    }

    @Test(arguments: WindowCommand.allCases)
    func everyCommandOnTheLaptop(_ command: WindowCommand) {
        let frame = WindowGeometry.frame(for: command, in: laptop, current: current)
        if stateCommands.contains(command) {
            #expect(frame == nil)
            #expect(!command.setsFrame || command == .restore)
        } else {
            #expect(frame == laptopExpectations[command])
            #expect(frame.map { laptop.contains($0) } == true, "\(command) leaves the visible frame")
        }
    }

    @Test(arguments: WindowCommand.allCases.filter { WindowGeometry.region($0) != nil })
    func tilesStayInsideEveryFixtureDisplay(_ command: WindowCommand) throws {
        for display in [WindowFixture.laptop, WindowFixture.secondary, WindowFixture.portrait] {
            let frame = try #require(
                WindowGeometry.frame(for: command, in: display.visibleFrame, current: current))
            #expect(display.visibleFrame.contains(frame), "\(command) on \(display.name)")
            #expect(frame.width >= 1 && frame.height >= 1)
        }
    }

    @Test func tilesUseSecondaryDisplayOriginsAndInsets() {
        let screen = WindowFixture.secondary.visibleFrame
        func frame(_ command: WindowCommand) -> CGRect? {
            WindowGeometry.frame(for: command, in: screen, current: current)
        }
        #expect(frame(.leftHalf) == CGRect(x: -1920, y: -200, width: 960, height: 1050))
        #expect(frame(.topHalf) == CGRect(x: -1920, y: 325, width: 1920, height: 525))
        #expect(frame(.lastThird) == CGRect(x: -640, y: -200, width: 640, height: 1050))
        #expect(frame(.secondFourth) == CGRect(x: -1440, y: -200, width: 480, height: 1050))
        #expect(frame(.topRightSixth) == CGRect(x: -640, y: 325, width: 640, height: 525))
        #expect(frame(.bottomRight) == CGRect(x: -960, y: -200, width: 960, height: 525))
        #expect(frame(.maximize) == screen)
        #expect(frame(.moveRight) == CGRect(x: -600, y: 200, width: 600, height: 400))
    }

    @Test func aLeftDockShiftsTheUsableArea() {
        #expect(
            WindowGeometry.frame(for: .leftHalf, in: WindowFixture.leftDock, current: current)
                == CGRect(x: 80, y: 0, width: 680, height: 876))
        #expect(
            WindowGeometry.frame(for: .moveLeft, in: WindowFixture.leftDock, current: current)
                == CGRect(x: 80, y: 200, width: 600, height: 400))
    }

    @Test func thirdsAndFourthsStackTopToBottomOnAPortraitDisplay() {
        let screen = WindowFixture.portrait.visibleFrame
        func frame(_ command: WindowCommand) -> CGRect? {
            WindowGeometry.frame(for: command, in: screen, current: current)
        }
        #expect(frame(.firstThird) == CGRect(x: 1440, y: 760, width: 1080, height: 630))
        #expect(frame(.centerThird) == CGRect(x: 1440, y: 130, width: 1080, height: 630))
        #expect(frame(.lastThird) == CGRect(x: 1440, y: -500, width: 1080, height: 630))
        #expect(frame(.firstTwoThirds) == CGRect(x: 1440, y: 130, width: 1080, height: 1260))
        #expect(frame(.lastTwoThirds) == CGRect(x: 1440, y: -500, width: 1080, height: 1260))
        #expect(frame(.firstFourth) == CGRect(x: 1440, y: 918, width: 1080, height: 472))
        #expect(frame(.lastFourth) == CGRect(x: 1440, y: -500, width: 1080, height: 472))
        #expect(frame(.secondFourth) == CGRect(x: 1440, y: 445, width: 1080, height: 473))
        // Halves, quarters and sixths keep their landscape meaning.
        #expect(frame(.leftHalf) == CGRect(x: 1440, y: -500, width: 540, height: 1890))
        #expect(frame(.topLeft) == CGRect(x: 1440, y: 445, width: 540, height: 945))
    }

    @Test(arguments: [
        [WindowCommand.leftHalf, .rightHalf],
        [.topHalf, .bottomHalf],
        [.firstThird, .centerThird, .lastThird],
        [.firstThird, .lastTwoThirds],
        [.firstTwoThirds, .lastThird],
        [.firstFourth, .secondFourth, .thirdFourth, .lastFourth],
        [.firstFourth, .lastThreeFourths],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth],
    ])
    func tileSetsCoverTheDisplayExactlyWithoutOverlap(_ commands: [WindowCommand]) throws {
        for display in [WindowFixture.laptop, WindowFixture.secondary, WindowFixture.portrait] {
            let screen = display.visibleFrame
            let frames = try commands.map {
                try #require(WindowGeometry.frame(for: $0, in: screen, current: current))
            }
            let area = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            #expect(area == screen.width * screen.height, "\(commands) on \(display.name)")
            for (index, frame) in frames.enumerated() {
                for other in frames[(index + 1)...] {
                    let overlap = frame.intersection(other)
                    #expect(overlap.isNull || overlap.width * overlap.height == 0)
                }
            }
        }
    }

    @Test func gapsSeparateNeighboursAndInsetTheDisplayEdges() throws {
        let gaps = WindowGaps(uniform: 10)
        let left = try #require(WindowGeometry.frame(for: .leftHalf, in: laptop, current: current, gaps: gaps))
        let right = try #require(WindowGeometry.frame(for: .rightHalf, in: laptop, current: current, gaps: gaps))
        #expect(left == CGRect(x: 10, y: 86, width: 705, height: 780))
        #expect(right == CGRect(x: 725, y: 86, width: 705, height: 780))
        #expect(right.minX - left.maxX == 10)
        #expect(WindowGeometry.frame(for: .maximize, in: laptop, current: current, gaps: gaps) == CGRect(
            x: 10, y: 86, width: 1420, height: 780))
        #expect(WindowGeometry.frame(for: .topLeft, in: laptop, current: current, gaps: gaps) == CGRect(
            x: 10, y: 481, width: 705, height: 385))
        let thirds = try [WindowCommand.firstThird, .centerThird, .lastThird].map {
            try #require(WindowGeometry.frame(for: $0, in: laptop, current: current, gaps: gaps))
        }
        #expect(thirds[0].minX == 10 && thirds[2].maxX == 1430)
        for (lhs, rhs) in zip(thirds, thirds.dropFirst()) { #expect(abs(rhs.minX - lhs.maxX - 10) <= 1) }
        // Moves and centering respect the screen gap too.
        #expect(WindowGeometry.frame(for: .moveLeft, in: laptop, current: current, gaps: gaps)?.minX == 10)
        #expect(WindowGeometry.frame(for: .moveUp, in: laptop, current: current, gaps: gaps)?.maxY == 866)
    }

    @Test func windowGapOnlyLeavesTheDisplayEdgesFlush() {
        let gaps = WindowGaps(window: 8, screen: 0)
        #expect(
            WindowGeometry.frame(for: .leftHalf, in: laptop, current: current, gaps: gaps)
                == CGRect(x: 0, y: 76, width: 716, height: 800))
        #expect(
            WindowGeometry.frame(for: .rightHalf, in: laptop, current: current, gaps: gaps)
                == CGRect(x: 724, y: 76, width: 716, height: 800))
        #expect(WindowGeometry.frame(for: .maximize, in: laptop, current: current, gaps: gaps) == laptop)
    }

    @Test func gapsAreClampedToASaneRange() {
        #expect(WindowGaps(uniform: 500).window == WindowGaps.maximum)
        #expect(WindowGaps(uniform: -4).screen == 0)
        #expect(WindowGaps(window: .nan, screen: .infinity) == .none)
        // A screen gap too large for a tiny display is ignored rather than inverting the frame.
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 150)
        #expect(WindowGeometry.usableArea(tiny, gaps: WindowGaps(uniform: 60)) == tiny)
    }

    @Test func centeringAndMovesShrinkOversizedWindowsToFit() {
        let huge = CGRect(x: -50, y: -50, width: 3000, height: 2000)
        #expect(WindowGeometry.frame(for: .center, in: laptop, current: huge) == laptop)
        #expect(WindowGeometry.frame(for: .moveRight, in: laptop, current: huge) == laptop)
        #expect(WindowGeometry.frame(for: .maximizeHeight, in: laptop, current: huge) == laptop)
        // A window hanging off the right edge is pulled back in.
        let offRight = CGRect(x: 1300, y: 200, width: 600, height: 400)
        #expect(
            WindowGeometry.frame(for: .maximizeHeight, in: laptop, current: offRight)
                == CGRect(x: 840, y: 76, width: 600, height: 800))
    }

    @Test func reasonableSizeCapsAtItsMaximumOnLargeDisplays() {
        let large = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        #expect(
            WindowGeometry.frame(for: .reasonableSize, in: large, current: current)
                == CGRect(x: 988, y: 550, width: 1025, height: 900))
    }

    @Test func makeLargerKeepsEdgesThatTouchTheDisplay() {
        let leftHalf = CGRect(x: 0, y: 76, width: 720, height: 800)
        // Full height stays full; the left edge stays put and the window grows right.
        #expect(
            WindowGeometry.frame(for: .makeLarger, in: laptop, current: leftHalf)
                == CGRect(x: 0, y: 76, width: 864, height: 800))
        let rightHalf = CGRect(x: 720, y: 76, width: 720, height: 800)
        #expect(
            WindowGeometry.frame(for: .makeSmaller, in: laptop, current: rightHalf)
                == CGRect(x: 864, y: 116, width: 576, height: 720))
        // Repeated growth stops at the display.
        var frame = current
        for _ in 0..<40 { frame = WindowGeometry.frame(for: .makeLarger, in: laptop, current: frame) ?? frame }
        #expect(frame == laptop)
    }

    @Test func makeSmallerStopsAtTheMinimumSize() {
        var frame = current
        for _ in 0..<40 { frame = WindowGeometry.frame(for: .makeSmaller, in: laptop, current: frame) ?? frame }
        #expect(frame.size == WindowGeometry.minimumSize)
        // A window already below the minimum doesn't grow when made smaller.
        let small = CGRect(x: 100, y: 100, width: 200, height: 150)
        #expect(WindowGeometry.frame(for: .makeSmaller, in: laptop, current: small)?.size == small.size)
    }

    // MARK: Cycling

    @Test func leftHalfCyclesThroughHalfTwoThirdsAndOneThird() {
        func next(_ frame: CGRect) -> CGRect? { HalfCycling.frame(for: .leftHalf, in: laptop, current: frame) }
        let half = CGRect(x: 0, y: 76, width: 720, height: 800)
        let twoThirds = CGRect(x: 0, y: 76, width: 960, height: 800)
        let third = CGRect(x: 0, y: 76, width: 480, height: 800)
        #expect(next(current) == half)
        #expect(next(half) == twoThirds)
        #expect(next(twoThirds) == third)
        #expect(next(third) == half)
        // Apps round their sizes; a couple of points off still counts.
        #expect(next(CGRect(x: 1, y: 77, width: 718, height: 799)) == twoThirds)
    }

    @Test func otherHalvesCycleFromTheirOwnEdge() {
        #expect(
            HalfCycling.frame(for: .rightHalf, in: laptop, current: CGRect(x: 720, y: 76, width: 720, height: 800))
                == CGRect(x: 480, y: 76, width: 960, height: 800))
        #expect(
            HalfCycling.frame(for: .rightHalf, in: laptop, current: CGRect(x: 480, y: 76, width: 960, height: 800))
                == CGRect(x: 960, y: 76, width: 480, height: 800))
        #expect(
            HalfCycling.frame(for: .topHalf, in: laptop, current: CGRect(x: 0, y: 476, width: 1440, height: 400))
                == CGRect(x: 0, y: 343, width: 1440, height: 533))
        #expect(
            HalfCycling.frame(for: .bottomHalf, in: laptop, current: CGRect(x: 0, y: 76, width: 1440, height: 400))
                == CGRect(x: 0, y: 76, width: 1440, height: 533))
        #expect(HalfCycling.frame(for: .maximize, in: laptop, current: current) == nil)
        #expect(WindowCommand.allCases.filter(\.cycles) == [.leftHalf, .rightHalf, .topHalf, .bottomHalf])
    }

    @Test func cyclingHonoursGaps() {
        let gaps = WindowGaps(uniform: 10)
        let half = WindowGeometry.frame(for: .leftHalf, in: laptop, current: current, gaps: gaps)!
        let next = HalfCycling.frame(for: .leftHalf, in: laptop, current: half, gaps: gaps)
        #expect(next?.minX == 10)
        #expect(next.map { abs($0.width - (1420 * 2 / 3 - 5)) <= 1 } == true)
    }

    // MARK: Displays

    @Test func displayArrangementFindsTheDisplayShowingMostOfAWindow() {
        let displays = [WindowFixture.laptop.frame, WindowFixture.secondary.frame, WindowFixture.portrait.frame]
        #expect(DisplayArrangement.index(of: current, in: displays) == 0)
        #expect(DisplayArrangement.index(of: CGRect(x: -400, y: 100, width: 600, height: 300), in: displays) == 1)
        #expect(DisplayArrangement.index(of: CGRect(x: 1500, y: -400, width: 300, height: 300), in: displays) == 2)
        // Entirely off every display: the nearest one.
        #expect(DisplayArrangement.index(of: CGRect(x: 5000, y: 0, width: 100, height: 100), in: displays) == 2)
        #expect(DisplayArrangement.index(of: current, in: []) == nil)
    }

    @Test func displaysAreOrderedLeftToRightThenTopToBottom() {
        let displays = [WindowFixture.laptop.frame, WindowFixture.secondary.frame, WindowFixture.portrait.frame]
        #expect(DisplayArrangement.spatialOrder(displays) == [1, 0, 2])
        #expect(DisplayArrangement.adjacent(to: 0, in: displays, forward: true) == 2)
        #expect(DisplayArrangement.adjacent(to: 0, in: displays, forward: false) == 1)
        #expect(DisplayArrangement.adjacent(to: 2, in: displays, forward: true) == 1)
        #expect(DisplayArrangement.adjacent(to: 1, in: displays, forward: false) == 2)
        #expect(DisplayArrangement.adjacent(to: 0, in: [WindowFixture.laptop.frame], forward: true) == nil)
        let stacked = [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 0, y: 100, width: 100, height: 100)]
        #expect(DisplayArrangement.spatialOrder(stacked) == [1, 0])
    }

    // MARK: Custom commands

    @Test func customCommandsResolvePointsPercentsAnchorsAndOffsets() {
        #expect(
            CustomWindowCommand.resize(width: 500, height: 300).frame(in: laptop, current: current)
                == CGRect(x: 100, y: 300, width: 500, height: 300))
        #expect(
            CustomWindowCommand.move(x: 50, y: 20).frame(in: laptop, current: current)
                == CGRect(x: 50, y: 456, width: 600, height: 400))
        let rightHalf = CustomWindowCommand(name: "Right", width: .percent(50), height: .percent(100), anchor: .right)
        #expect(rightHalf.frame(in: laptop, current: current) == CGRect(x: 720, y: 76, width: 720, height: 800))
        let nudged = CustomWindowCommand(
            name: "Nudged", width: .points(400), height: .points(200), anchor: .center, xOffset: .percent(10),
            yOffset: .percent(-10))
        #expect(nudged.frame(in: laptop, current: current) == CGRect(x: 664, y: 456, width: 400, height: 200))
        let bottomLeft = CustomWindowCommand(name: "Corner", anchor: .bottomLeft)
        #expect(bottomLeft.frame(in: laptop, current: current) == CGRect(x: 0, y: 76, width: 600, height: 400))
        let oversized = CustomWindowCommand(name: "Wide", width: .points(5000), anchor: .topLeft)
        #expect(oversized.frame(in: laptop, current: current).width == 1440)
        #expect(Set(WindowAnchor.allCases.map(\.title)).count == WindowAnchor.allCases.count)
    }

    @Test func customCommandValidationRejectsImpossibleValues() throws {
        try CustomWindowCommand(name: "Ok", width: .percent(100), xOffset: .percent(-100)).validate()
        let invalid = [
            CustomWindowCommand(name: "  "),
            CustomWindowCommand(name: String(repeating: "x", count: 61)),
            CustomWindowCommand(name: "Zero", width: .percent(0)),
            CustomWindowCommand(name: "Big", height: .percent(150)),
            CustomWindowCommand(name: "Negative", width: .points(-10)),
            CustomWindowCommand(name: "Far", xOffset: .percent(-101)),
            CustomWindowCommand(name: "NaN", yOffset: .points(.nan)),
        ]
        for command in invalid {
            #expect(throws: LibraryValidationError.self) { try command.validate() }
        }
    }

    @Test func customCommandsRoundTripThroughJSON() throws {
        let command = CustomWindowCommand(
            name: "Left 40%", width: .percent(40), height: nil, anchor: .left, xOffset: .points(12),
            yOffset: .percent(-5))
        let decoded = try JSONDecoder().decode(CustomWindowCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded == command)
    }

    // MARK: Catalog

    @Test func originalLayoutsMapToCommandsWithTheSameIdentifiers() {
        for layout in WindowLayout.allCases {
            #expect(layout.command.rawValue == layout.rawValue)
        }
        // The original API returns the same frames as before.
        for layout in WindowLayout.allCases where layout != .restore && layout != .nextDisplay {
            #expect(
                layout.frame(in: laptop, current: current)
                    == WindowGeometry.frame(for: layout.command, in: laptop, current: current))
        }
        #expect(WindowLayout.restore.frame(in: laptop, current: current) == current)
    }

    @Test func commandMetadataIsCompleteAndUnique() {
        let commands = WindowCommand.allCases
        #expect(Set(commands.map(\.title)).count == commands.count)
        #expect(commands.allSatisfy { !$0.symbol.isEmpty && $0.keywords.hasPrefix("window") })
        for group in WindowCommand.Group.allCases {
            #expect(commands.contains { $0.group == group }, "\(group) has no commands")
            #expect(!group.title.isEmpty)
        }
        #expect(commands.count == 44)
    }

    @Test func unitRectsNormalizeAndClampFrames() {
        let region = UnitRect(CGRect(x: 360, y: 476, width: 720, height: 400), in: laptop)
        #expect(region == UnitRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5))
        #expect(WindowGeometry.place(region, in: laptop) == CGRect(x: 360, y: 476, width: 720, height: 400))
        let clamped = UnitRect(CGRect(x: -100, y: 0, width: 400, height: 2000), in: laptop)
        #expect(clamped.x == 0 && clamped.maxY == 1)
        #expect(!UnitRect(x: 0.5, y: 0, width: 0.6, height: 1).isValid)
        #expect(UnitRect.full.isValid)
        let portrait = UnitRect(x: 0, y: 0, width: 1.0 / 3, height: 1).portrait
        #expect(portrait.x == 0 && portrait.width == 1)
        #expect(abs(portrait.y - 2.0 / 3) < 1e-9 && abs(portrait.height - 1.0 / 3) < 1e-9)
    }
}
