import AppKit
import CoreGraphics

// MARK: - Commands

/// Every window command. The launcher's original twelve (`WindowLayout`) map onto
/// these with the same identifiers, so usage history and bindings keep working.
enum WindowCommand: String, CaseIterable, Identifiable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, centerHalf
    case firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds
    case firstFourth, secondFourth, thirdFourth, lastFourth, firstThreeFourths, lastThreeFourths
    case topLeft, topRight, bottomLeft, bottomRight
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, almostMaximize, maximizeHeight, maximizeWidth, reasonableSize, center
    case makeLarger, makeSmaller
    case moveUp, moveDown, moveLeft, moveRight
    case nextDisplay, previousDisplay
    case toggleFullscreen, minimize, restore

    var id: String { rawValue }

    enum Group: String, CaseIterable, Sendable {
        case halves, thirds, fourths, quarters, sixths, size, move, display, state

        var title: String {
            switch self {
            case .halves: "Halves"
            case .thirds: "Thirds"
            case .fourths: "Fourths"
            case .quarters: "Quarters"
            case .sixths: "Sixths"
            case .size: "Size"
            case .move: "Move"
            case .display: "Displays"
            case .state: "Window"
            }
        }
    }

    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf: .halves
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: .thirds
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .lastThreeFourths: .fourths
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .quarters
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            .sixths
        case .maximize, .almostMaximize, .maximizeHeight, .maximizeWidth, .reasonableSize, .center, .makeLarger,
            .makeSmaller:
            .size
        case .moveUp, .moveDown, .moveLeft, .moveRight: .move
        case .nextDisplay, .previousDisplay: .display
        case .toggleFullscreen, .minimize, .restore: .state
        }
    }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .centerHalf: "Center Half"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .firstFourth: "First Fourth"
        case .secondFourth: "Second Fourth"
        case .thirdFourth: "Third Fourth"
        case .lastFourth: "Last Fourth"
        case .firstThreeFourths: "First Three Fourths"
        case .lastThreeFourths: "Last Three Fourths"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .topLeftSixth: "Top Left Sixth"
        case .topCenterSixth: "Top Center Sixth"
        case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"
        case .bottomCenterSixth: "Bottom Center Sixth"
        case .bottomRightSixth: "Bottom Right Sixth"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .maximizeWidth: "Maximize Width"
        case .reasonableSize: "Reasonable Size"
        case .center: "Center"
        case .makeLarger: "Make Larger"
        case .makeSmaller: "Make Smaller"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .toggleFullscreen: "Toggle Fullscreen"
        case .minimize: "Minimize"
        case .restore: "Restore"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .centerHalf, .center: "rectangle.center.inset.filled"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds:
            "rectangle.split.3x1"
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .firstThreeFourths, .lastThreeFourths:
            "rectangle.split.3x1"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: "rectangle.split.2x2"
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            "rectangle.split.3x3"
        case .maximize: "arrow.up.left.and.arrow.down.right"
        case .almostMaximize: "rectangle.inset.filled"
        case .maximizeHeight: "arrow.up.and.down"
        case .maximizeWidth: "arrow.left.and.right"
        case .reasonableSize: "macwindow"
        case .makeLarger: "plus.rectangle"
        case .makeSmaller: "minus.rectangle"
        case .moveUp: "arrow.up.to.line"
        case .moveDown: "arrow.down.to.line"
        case .moveLeft: "arrow.left.to.line"
        case .moveRight: "arrow.right.to.line"
        case .nextDisplay, .previousDisplay: "display.2"
        case .toggleFullscreen: "arrow.up.backward.and.arrow.down.forward"
        case .minimize: "dock.arrow.down.rectangle"
        case .restore: "arrow.uturn.backward"
        }
    }

    var keywords: String {
        var words = "window resize move tile"
        switch group {
        case .halves: words += " half split snap"
        case .thirds: words += " third thirds column"
        case .fourths: words += " fourth fourths column"
        case .quarters: words += " quarter corner"
        case .sixths: words += " sixth grid"
        case .size: words += " size full larger smaller"
        case .move: words += " edge position"
        case .display: words += " display monitor screen"
        case .state: words += " fullscreen minimize restore undo"
        }
        return words
    }

    /// Repeating these cycles the window through 1/2, 2/3 and 1/3 when half cycling is on.
    var cycles: Bool { [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains(self) }

    /// Fullscreen and Minimize change the window's state; everything else sets a frame.
    var setsFrame: Bool { self != .toggleFullscreen && self != .minimize }
}

extension WindowLayout {
    /// The full command behind each of the launcher's original window layouts.
    var command: WindowCommand {
        switch self {
        case .leftHalf: .leftHalf
        case .rightHalf: .rightHalf
        case .topHalf: .topHalf
        case .bottomHalf: .bottomHalf
        case .maximize: .maximize
        case .center: .center
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        case .nextDisplay: .nextDisplay
        case .restore: .restore
        }
    }
}

// MARK: - Geometry

/// A region of a display in unit fractions, origin at the bottom-left like AppKit.
struct UnitRect: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    /// Columns become rows on a portrait display, read top to bottom.
    var portrait: UnitRect { UnitRect(x: 1 - maxY, y: 1 - maxX, width: height, height: width) }

    /// The share of `area` that `rect` covers, clamped to the display.
    init(_ rect: CGRect, in area: CGRect) {
        guard area.width > 0, area.height > 0 else {
            self = .full
            return
        }
        let minX = min(max((rect.minX - area.minX) / area.width, 0), 1)
        let minY = min(max((rect.minY - area.minY) / area.height, 0), 1)
        let maxX = min(max((rect.maxX - area.minX) / area.width, 0), 1)
        let maxY = min(max((rect.maxY - area.minY) / area.height, 0), 1)
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && maxX <= 1.000_1 && maxY <= 1.000_1
    }
}

/// Space between tiled windows and between windows and the display's edges.
struct WindowGaps: Equatable, Codable, Sendable {
    static let maximum: Double = 64
    static let none = WindowGaps()

    /// Between neighbouring windows.
    var window: Double = 0
    /// Between windows and the edges of the display.
    var screen: Double = 0

    init(window: Double = 0, screen: Double = 0) {
        self.window = Self.clamp(window)
        self.screen = Self.clamp(screen)
    }

    /// One gap everywhere, as in a single "Window Gap" setting.
    init(uniform gap: Double) { self.init(window: gap, screen: gap) }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), maximum) : 0
    }
}

/// Where each window command puts a window. Every frame uses AppKit's bottom-left
/// coordinates; `screen` is a display's visible frame, so the menu bar and Dock stay clear.
enum WindowGeometry {
    /// Almost Maximize fills this share of the display.
    static let almostMaximizeFraction = 0.9
    /// Reasonable Size: 60% of the display, at most 1025 × 900 points.
    static let reasonableFraction = 0.6
    static let reasonableMaximum = CGSize(width: 1025, height: 900)
    /// Make Larger and Make Smaller change each side by this share of the display.
    static let resizeStepFraction = 0.05
    /// Make Smaller stops here, or at the window's current size when it is already smaller.
    static let minimumSize = CGSize(width: 320, height: 200)
    /// Frames within this many points count as the same, since apps round their sizes.
    static let tolerance: CGFloat = 3

    /// The region a tiling command covers on a landscape display.
    static func region(_ command: WindowCommand) -> UnitRect? {
        let third = 1.0 / 3
        switch command {
        case .leftHalf: return UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return UnitRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .bottomHalf: return UnitRect(x: 0, y: 0, width: 1, height: 0.5)
        case .centerHalf: return UnitRect(x: 0.25, y: 0, width: 0.5, height: 1)
        case .firstThird: return UnitRect(x: 0, y: 0, width: third, height: 1)
        case .centerThird: return UnitRect(x: third, y: 0, width: third, height: 1)
        case .lastThird: return UnitRect(x: 2 * third, y: 0, width: third, height: 1)
        case .firstTwoThirds: return UnitRect(x: 0, y: 0, width: 2 * third, height: 1)
        case .centerTwoThirds: return UnitRect(x: third / 2, y: 0, width: 2 * third, height: 1)
        case .lastTwoThirds: return UnitRect(x: third, y: 0, width: 2 * third, height: 1)
        case .firstFourth: return UnitRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: return UnitRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: return UnitRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: return UnitRect(x: 0.75, y: 0, width: 0.25, height: 1)
        case .firstThreeFourths: return UnitRect(x: 0, y: 0, width: 0.75, height: 1)
        case .lastThreeFourths: return UnitRect(x: 0.25, y: 0, width: 0.75, height: 1)
        case .topLeft: return UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .topRight: return UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .bottomLeft: return UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .bottomRight: return UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .topLeftSixth: return UnitRect(x: 0, y: 0.5, width: third, height: 0.5)
        case .topCenterSixth: return UnitRect(x: third, y: 0.5, width: third, height: 0.5)
        case .topRightSixth: return UnitRect(x: 2 * third, y: 0.5, width: third, height: 0.5)
        case .bottomLeftSixth: return UnitRect(x: 0, y: 0, width: third, height: 0.5)
        case .bottomCenterSixth: return UnitRect(x: third, y: 0, width: third, height: 0.5)
        case .bottomRightSixth: return UnitRect(x: 2 * third, y: 0, width: third, height: 0.5)
        case .maximize: return .full
        default: return nil
        }
    }

    /// Thirds and fourths stack top to bottom on a portrait display.
    static func region(_ command: WindowCommand, portrait: Bool) -> UnitRect? {
        guard let region = region(command) else { return nil }
        guard portrait else { return region }
        switch command.group {
        case .thirds, .fourths: return region.portrait
        default: return region
        }
    }

    /// The frame `command` gives a window whose frame is `current`. For Next and
    /// Previous Display, `screen` is the target display. Nil for commands that
    /// don't set a frame: Toggle Fullscreen, Minimize and Restore.
    static func frame(
        for command: WindowCommand, in screen: CGRect, current: CGRect, gaps: WindowGaps = .none
    ) -> CGRect? {
        let usable = usableArea(screen, gaps: gaps)
        if let region = region(command, portrait: screen.height > screen.width) {
            return place(region, in: screen, gaps: gaps)
        }
        switch command {
        case .almostMaximize:
            return centered(
                CGSize(width: usable.width * almostMaximizeFraction, height: usable.height * almostMaximizeFraction),
                in: usable)
        case .reasonableSize:
            return centered(
                CGSize(
                    width: min(usable.width * reasonableFraction, reasonableMaximum.width),
                    height: min(usable.height * reasonableFraction, reasonableMaximum.height)), in: usable)
        case .maximizeHeight:
            let width = min(current.width, usable.width)
            return rounded(
                CGRect(
                    x: clamp(current.minX, usable.minX, usable.maxX - width), y: usable.minY, width: width,
                    height: usable.height))
        case .maximizeWidth:
            let height = min(current.height, usable.height)
            return rounded(
                CGRect(
                    x: usable.minX, y: clamp(current.minY, usable.minY, usable.maxY - height), width: usable.width,
                    height: height))
        case .center, .nextDisplay, .previousDisplay:
            return centered(current.size, in: usable)
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            let size = CGSize(width: min(current.width, usable.width), height: min(current.height, usable.height))
            var x = clamp(current.minX, usable.minX, usable.maxX - size.width)
            var y = clamp(current.minY, usable.minY, usable.maxY - size.height)
            switch command {
            case .moveLeft: x = usable.minX
            case .moveRight: x = usable.maxX - size.width
            case .moveUp: y = usable.maxY - size.height
            default: y = usable.minY
            }
            return rounded(CGRect(origin: CGPoint(x: x, y: y), size: size))
        case .makeLarger, .makeSmaller:
            let sign: CGFloat = command == .makeLarger ? 1 : -1
            let horizontal = resize(
                current.minX, current.maxX, by: sign * usable.width * resizeStepFraction * 2,
                within: usable.minX, usable.maxX, minimum: minimumSize.width)
            let vertical = resize(
                current.minY, current.maxY, by: sign * usable.height * resizeStepFraction * 2,
                within: usable.minY, usable.maxY, minimum: minimumSize.height)
            return rounded(
                CGRect(x: horizontal.start, y: vertical.start, width: horizontal.length, height: vertical.length))
        default:
            return nil
        }
    }

    /// The display area left after the screen gap.
    static func usableArea(_ screen: CGRect, gaps: WindowGaps) -> CGRect {
        let inset = CGFloat(gaps.screen)
        guard screen.width > inset * 4, screen.height > inset * 4 else { return screen }
        return screen.insetBy(dx: inset, dy: inset)
    }

    /// A unit region on a display. Inner edges give up half the window gap each,
    /// so neighbours end up one full gap apart. Edges round to whole points so
    /// neighbouring tiles meet exactly.
    static func place(_ region: UnitRect, in screen: CGRect, gaps: WindowGaps = .none) -> CGRect {
        let usable = usableArea(screen, gaps: gaps)
        let half = CGFloat(gaps.window) / 2
        let epsilon = 0.000_1
        var minX = usable.minX + usable.width * region.x
        var maxX = usable.minX + usable.width * region.maxX
        var minY = usable.minY + usable.height * region.y
        var maxY = usable.minY + usable.height * region.maxY
        if region.x > epsilon { minX += half }
        if region.maxX < 1 - epsilon { maxX -= half }
        if region.y > epsilon { minY += half }
        if region.maxY < 1 - epsilon { maxY -= half }
        minX.round()
        maxX.round()
        minY.round()
        maxY.round()
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    /// A size centered in an area, shrunk to fit.
    static func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        return rounded(CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height))
    }

    static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = tolerance) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    /// Grows or shrinks one axis. An edge that touches the display stays put, so a
    /// window tiled to the left grows to the right.
    private static func resize(
        _ start: CGFloat, _ end: CGFloat, by delta: CGFloat, within low: CGFloat, _ high: CGFloat, minimum: CGFloat
    ) -> (start: CGFloat, length: CGFloat) {
        let available = high - low
        let length = min(end - start, available)
        let newLength =
            delta >= 0 ? min(length + delta, available) : max(length + delta, min(length, minimum, available))
        let touchesLow = abs(start - low) <= tolerance
        let touchesHigh = abs(end - high) <= tolerance
        var newStart: CGFloat
        if touchesLow && !touchesHigh {
            newStart = start
        } else if touchesHigh && !touchesLow {
            newStart = end - newLength
        } else {
            newStart = (start + end) / 2 - newLength / 2
        }
        newStart = clamp(newStart, low, high - newLength)
        return (newStart, newLength)
    }

    static func rounded(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width.rounded(), height: rect.height.rounded())
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, max(low, high)))
    }
}

/// Repeating Left, Right, Top or Bottom Half steps the window through 1/2, 2/3 and 1/3.
enum HalfCycling {
    static let fractions: [Double] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    static func region(_ command: WindowCommand, fraction: Double) -> UnitRect? {
        switch command {
        case .leftHalf: UnitRect(x: 0, y: 0, width: fraction, height: 1)
        case .rightHalf: UnitRect(x: 1 - fraction, y: 0, width: fraction, height: 1)
        case .topHalf: UnitRect(x: 0, y: 1 - fraction, width: 1, height: fraction)
        case .bottomHalf: UnitRect(x: 0, y: 0, width: 1, height: fraction)
        default: nil
        }
    }

    /// The next size in the cycle: the step after the one the window already fills,
    /// or the half when it fills none of them.
    static func frame(
        for command: WindowCommand, in screen: CGRect, current: CGRect, gaps: WindowGaps = .none
    ) -> CGRect? {
        let frames = fractions.compactMap { region(command, fraction: $0) }.map {
            WindowGeometry.place($0, in: screen, gaps: gaps)
        }
        guard !frames.isEmpty else { return nil }
        guard let index = frames.firstIndex(where: { WindowGeometry.approximatelyEqual($0, current) }) else {
            return frames[0]
        }
        return frames[(index + 1) % frames.count]
    }
}

/// Which display a window is on, and which one is next.
enum DisplayArrangement {
    /// The display showing most of `frame`, or the nearest one when it's on none.
    static func index(of frame: CGRect, in displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let areas = displays.map { display -> CGFloat in
            let overlap = display.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.indices.min { distance(center, displays[$0]) < distance(center, displays[$1]) }
    }

    /// Displays in reading order: left to right, then top to bottom.
    static func spatialOrder(_ displays: [CGRect]) -> [Int] {
        displays.indices.sorted { lhs, rhs in
            let a = displays[lhs]
            let b = displays[rhs]
            if a.minX != b.minX { return a.minX < b.minX }
            if a.maxY != b.maxY { return a.maxY > b.maxY }
            return lhs < rhs
        }
    }

    /// The display after (or before) `index` in reading order, wrapping around.
    /// Nil with a single display.
    static func adjacent(to index: Int, in displays: [CGRect], forward: Bool) -> Int? {
        guard displays.count > 1, displays.indices.contains(index) else { return nil }
        let order = spatialOrder(displays)
        guard let position = order.firstIndex(of: index) else { return nil }
        let next = (position + (forward ? 1 : order.count - 1)) % order.count
        return order[next]
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: - Custom commands

/// A size or offset, absolute or as a share of the display.
enum WindowDimension: Codable, Equatable, Sendable {
    case points(Double)
    case percent(Double)

    func resolve(against length: CGFloat) -> CGFloat {
        switch self {
        case .points(let value): CGFloat(value)
        case .percent(let value): length * CGFloat(value) / 100
        }
    }
}

/// Where a custom command pins the window before applying offsets.
enum WindowAnchor: String, Codable, CaseIterable, Sendable {
    /// Keeps the window's top-left corner where it is.
    case current
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var title: String {
        switch self {
        case .current: "Current Position"
        case .topLeft: "Top Left"
        case .top: "Top"
        case .topRight: "Top Right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// A user-defined size and position, also used for exact Move and Resize.
/// Custom commands ignore window gaps.
struct CustomWindowCommand: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Nil keeps the window's current width or height.
    var width: WindowDimension?
    var height: WindowDimension?
    var anchor: WindowAnchor = .center
    /// Positive moves right.
    var xOffset: WindowDimension = .points(0)
    /// Positive moves down, as people read a screen.
    var yOffset: WindowDimension = .points(0)

    /// Resize Window: an exact size, keeping the top-left corner.
    static func resize(width: Double, height: Double) -> CustomWindowCommand {
        CustomWindowCommand(name: "Resize Window", width: .points(width), height: .points(height), anchor: .current)
    }

    /// Move Window: an exact top-left position on the display, keeping the size.
    static func move(x: Double, y: Double) -> CustomWindowCommand {
        CustomWindowCommand(name: "Move Window", anchor: .topLeft, xOffset: .points(x), yOffset: .points(y))
    }

    func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else {
            throw LibraryValidationError("Name the command with up to 60 characters.")
        }
        for size in [width, height].compactMap({ $0 }) {
            switch size {
            case .points(let value) where !(value.isFinite && value > 0 && value <= 20_000),
                .percent(let value) where !(value.isFinite && value > 0 && value <= 100):
                throw LibraryValidationError("Sizes must be above zero and at most 100% of the display.")
            default: break
            }
        }
        for offset in [xOffset, yOffset] {
            switch offset {
            case .points(let value) where !(value.isFinite && abs(value) <= 20_000),
                .percent(let value) where !(value.isFinite && abs(value) <= 100):
                throw LibraryValidationError("Offsets must be between −100% and +100% of the display.")
            default: break
            }
        }
    }

    /// The frame on a display's visible area, in AppKit coordinates.
    func frame(in screen: CGRect, current: CGRect) -> CGRect {
        let width = min(max(width?.resolve(against: screen.width) ?? current.width, 1), screen.width)
        let height = min(max(height?.resolve(against: screen.height) ?? current.height, 1), screen.height)
        let left = screen.minX
        let middle = screen.midX - width / 2
        let right = screen.maxX - width
        let top = screen.maxY - height
        let center = screen.midY - height / 2
        let bottom = screen.minY
        let origin =
            switch anchor {
            case .current: CGPoint(x: current.minX, y: current.maxY - height)
            case .topLeft: CGPoint(x: left, y: top)
            case .top: CGPoint(x: middle, y: top)
            case .topRight: CGPoint(x: right, y: top)
            case .left: CGPoint(x: left, y: center)
            case .center: CGPoint(x: middle, y: center)
            case .right: CGPoint(x: right, y: center)
            case .bottomLeft: CGPoint(x: left, y: bottom)
            case .bottom: CGPoint(x: middle, y: bottom)
            case .bottomRight: CGPoint(x: right, y: bottom)
            }
        var x = origin.x
        var y = origin.y
        x += xOffset.resolve(against: screen.width)
        y -= yOffset.resolve(against: screen.height)
        return WindowGeometry.rounded(CGRect(x: x, y: y, width: width, height: height))
    }
}

// MARK: - Saved layouts

/// A saved arrangement of several apps' windows across displays.
struct SavedWindowLayout: Codable, Equatable, Identifiable, Sendable {
    static let maximumWindowsPerDisplay = 8

    /// What happens to windows the layout doesn't place, on the displays it uses.
    enum OtherWindows: String, Codable, CaseIterable, Sendable {
        case leave, minimize, close

        var title: String {
            switch self {
            case .leave: "Leave Open"
            case .minimize: "Minimize Others"
            case .close: "Close Others"
            }
        }
    }

    struct Slot: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var bundleIdentifier: String
        var appName: String
        /// Picks this window when the app has several.
        var windowTitle: String?
        /// The display's position in reading order when the layout was saved.
        var displayIndex: Int
        /// Matches the same display again after the arrangement changes.
        var displayName: String?
        /// The window's share of the display's visible area.
        var region: UnitRect
    }

    var id = UUID()
    var name: String
    /// Front to back: the first slot ends up frontmost.
    var slots: [Slot]
    var otherWindows: OtherWindows = .leave

    func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else {
            throw LibraryValidationError("Name the layout with up to 60 characters.")
        }
        guard !slots.isEmpty else { throw LibraryValidationError("Add at least one window to the layout.") }
        let perDisplay = Dictionary(grouping: slots, by: \.displayIndex)
        guard perDisplay.values.allSatisfy({ $0.count <= Self.maximumWindowsPerDisplay }) else {
            throw LibraryValidationError(
                "A layout can place up to \(Self.maximumWindowsPerDisplay) windows on each display.")
        }
        guard slots.allSatisfy({ $0.region.isValid && $0.displayIndex >= 0 && !$0.bundleIdentifier.isEmpty }) else {
            throw LibraryValidationError("Every window in the layout needs an app and a size on the display.")
        }
    }
}

/// What applying a layout does, worked out before anything moves.
struct WindowLayoutPlan: Equatable {
    struct Move: Equatable {
        var slotID: UUID
        var window: WindowHandle
        var frame: CGRect
        var unminimize: Bool
    }

    var moves: [Move] = []
    /// Apps with a slot but no window: launch them, then plan again.
    var launches: [String] = []
    var unmatchedSlots: [UUID] = []
    /// Windows to minimize or close under the layout's Other Windows setting.
    var others: [WindowHandle] = []
}

enum WindowLayoutPlanner {
    /// Matches slots to windows. Each slot takes the window with its saved title,
    /// else the app's frontmost unclaimed window; visible windows go before minimized ones.
    static func plan(
        _ layout: SavedWindowLayout, displays: [DisplaySnapshot], windows: [WindowSnapshot]
    ) -> WindowLayoutPlan {
        var plan = WindowLayoutPlan()
        guard !displays.isEmpty else {
            plan.unmatchedSlots = layout.slots.map(\.id)
            return plan
        }
        let candidates = windows.filter { !$0.isMinimized } + windows.filter(\.isMinimized)
        var claimed = Set<WindowHandle>()
        var usedDisplays = Set<Int>()
        for slot in layout.slots {
            let displayIndex = self.displayIndex(for: slot, in: displays)
            usedDisplays.insert(displayIndex)
            let appWindows = candidates.filter {
                $0.bundleIdentifier == slot.bundleIdentifier && !claimed.contains($0.handle)
            }
            let match =
                slot.windowTitle.flatMap { title in appWindows.first { $0.title == title } } ?? appWindows.first
            guard let match else {
                plan.unmatchedSlots.append(slot.id)
                if !plan.launches.contains(slot.bundleIdentifier) { plan.launches.append(slot.bundleIdentifier) }
                continue
            }
            claimed.insert(match.handle)
            plan.moves.append(
                .init(
                    slotID: slot.id, window: match.handle,
                    frame: WindowGeometry.place(slot.region, in: displays[displayIndex].visibleFrame),
                    unminimize: match.isMinimized))
        }
        if layout.otherWindows != .leave {
            let frames = displays.map(\.frame)
            plan.others = windows.filter { window in
                !window.isMinimized && !claimed.contains(window.handle)
                    && DisplayArrangement.index(of: window.frame, in: frames).map(usedDisplays.contains) == true
            }.map(\.handle)
        }
        return plan
    }

    /// The display a slot belongs on: the one with its saved name, else the same
    /// position in reading order, else the main display.
    static func displayIndex(for slot: SavedWindowLayout.Slot, in displays: [DisplaySnapshot]) -> Int {
        if let name = slot.displayName {
            let named = displays.indices.filter { displays[$0].name == name }
            if named.count == 1 { return named[0] }
        }
        let order = DisplayArrangement.spatialOrder(displays.map(\.frame))
        if order.indices.contains(slot.displayIndex) { return order[slot.displayIndex] }
        return 0
    }

    /// Save Current Layout: the visible windows, front to back, up to eight per display.
    static func capture(
        named name: String, displays: [DisplaySnapshot], windows: [WindowSnapshot]
    ) -> SavedWindowLayout {
        let frames = displays.map(\.frame)
        let order = DisplayArrangement.spatialOrder(frames)
        var perDisplay: [Int: Int] = [:]
        var slots: [SavedWindowLayout.Slot] = []
        for window in windows where !window.isMinimized {
            guard let bundleIdentifier = window.bundleIdentifier, !bundleIdentifier.isEmpty,
                let index = DisplayArrangement.index(of: window.frame, in: frames),
                let position = order.firstIndex(of: index),
                perDisplay[index, default: 0] < SavedWindowLayout.maximumWindowsPerDisplay
            else { continue }
            let region = UnitRect(window.frame, in: displays[index].visibleFrame)
            guard region.width > 0, region.height > 0 else { continue }
            perDisplay[index, default: 0] += 1
            slots.append(
                .init(
                    bundleIdentifier: bundleIdentifier, appName: window.appName,
                    windowTitle: window.title.isEmpty ? nil : window.title, displayIndex: position,
                    displayName: displays[index].name, region: region))
        }
        return SavedWindowLayout(name: name, slots: slots)
    }
}

/// Opens apps that a layout needs. Behind a protocol so tests never launch anything.
@MainActor
protocol ApplicationLaunching: AnyObject {
    func launch(bundleIdentifier: String) async throws
}

@MainActor
final class WorkspaceApplicationLauncher: ApplicationLaunching {
    func launch(bundleIdentifier: String) async throws {
        try SideEffectGuard.check("launching \(bundleIdentifier)")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw LibraryValidationError("An app in this layout isn't installed.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

/// What applying a layout did.
struct WindowLayoutOutcome: Equatable, Sendable {
    var placed: Int
    /// Apps that had no window to place, by name.
    var missing: [String]

    var message: String {
        if missing.isEmpty { return placed == 1 ? "Arranged 1 window" : "Arranged \(placed) windows" }
        return "Arranged \(placed) of \(placed + missing.count) windows. No window for \(missing.joined(separator: ", "))"
    }
}
