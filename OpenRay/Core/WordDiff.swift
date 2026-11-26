import Foundation

/// A word-level diff between a passage and its transformed version.
/// Deletions and insertions are paired, so “4 corrections” counts edits, not tokens.
struct WordDiff: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    var segments: [Segment]

    /// The number of separate edits, where a replacement counts once.
    var changeCount: Int {
        var count = 0
        var inChange = false
        for segment in segments {
            switch segment {
            case .same(let text):
                // Whitespace between two edits doesn't split a replacement into two.
                if !text.allSatisfy(\.isWhitespace) { inChange = false }
            case .removed, .added:
                if !inChange { count += 1 }
                inChange = true
            }
        }
        return count
    }

    var isUnchanged: Bool { segments.allSatisfy { if case .same = $0 { true } else { false } } }

    init(segments: [Segment]) { self.segments = segments }

    /// Myers' diff runs in O((N + M) · D) time and linear space, so every passage up to the
    /// 6,000-character input limit, and its result, gets a real diff. Longer text falls back
    /// to a whole replacement.
    static let tokenLimit = 16_000

    init(from original: String, to revised: String) {
        let old = Self.tokenize(original)
        let new = Self.tokenize(revised)
        guard old.count + new.count <= Self.tokenLimit else {
            segments =
                original == revised
                ? [.same(original)] : Self.groupReplacements([.removed(original), .added(revised)])
            return
        }
        var script = EditScript(old: old, new: new)
        script.diff(0..<old.count, 0..<new.count)
        segments = Self.groupReplacements(script.segments)
    }

    /// Orders each run of edits as removals, then additions, so “monday” → “Monday”
    /// reads as one struck word followed by its replacement.
    private static func groupReplacements(_ segments: [Segment]) -> [Segment] {
        var output: [Segment] = []
        var removed = ""
        var added = ""
        func flush() {
            if !removed.isEmpty { output.append(.removed(removed)) }
            if !added.isEmpty { output.append(.added(added)) }
            removed = ""
            added = ""
        }
        for segment in segments {
            switch segment {
            case .removed(let text): removed += text
            case .added(let text): added += text
            case .same:
                flush()
                output.append(segment)
            }
        }
        flush()
        return output
    }

    /// Words, whitespace runs and single punctuation marks, so every character is kept.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind = 0  // 1 word, 2 space
        for character in text {
            let kind: Int
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                kind = 1
            } else if character.isWhitespace {
                kind = 2
            } else {
                kind = 3
            }
            if kind == 3 {
                if !current.isEmpty { tokens.append(current) }
                tokens.append(String(character))
                current = ""
                currentKind = 0
            } else if kind == currentKind {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(character)
                currentKind = kind
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// The shortest edit script between two token lists: Myers' linear-space bisection, as in
/// diff-match-patch. Tokens are compared as interned integers, and the common prefix and
/// suffix are matched first, so a one-word fix in a long passage costs almost nothing.
private struct EditScript {
    private enum Kind { case same, removed, added }

    private let old: [String]
    private let new: [String]
    private let a: [Int]
    private let b: [Int]
    private(set) var segments: [WordDiff.Segment] = []

    init(old: [String], new: [String]) {
        self.old = old
        self.new = new
        var ids: [String: Int] = [:]
        func intern(_ tokens: [String]) -> [Int] {
            tokens.map { token -> Int in
                if let id = ids[token] { return id }
                let id = ids.count
                ids[token] = id
                return id
            }
        }
        a = intern(old)
        b = intern(new)
    }

    mutating func diff(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        var aLow = oldRange.lowerBound
        var aHigh = oldRange.upperBound
        var bLow = newRange.lowerBound
        var bHigh = newRange.upperBound
        while aLow < aHigh, bLow < bHigh, a[aLow] == b[bLow] {
            aLow += 1
            bLow += 1
        }
        while aLow < aHigh, bLow < bHigh, a[aHigh - 1] == b[bHigh - 1] {
            aHigh -= 1
            bHigh -= 1
        }
        emit(.same, oldRange.lowerBound..<aLow)
        if aLow == aHigh || bLow == bHigh {
            emit(.removed, aLow..<aHigh)
            emit(.added, bLow..<bHigh)
        } else {
            bisect(aLow..<aHigh, bLow..<bHigh)
        }
        emit(.same, aHigh..<oldRange.upperBound)
    }

    /// Walks forward from the start and backward from the end until the paths meet, then
    /// diffs each half. Both ranges are non-empty and differ at their first and last tokens.
    private mutating func bisect(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
        let aStart = oldRange.lowerBound
        let bStart = newRange.lowerBound
        let n = oldRange.count
        let m = newRange.count
        let maxD = (n + m + 1) / 2
        let offset = maxD
        // Two spare slots keep the seed at offset + 1 in bounds for the smallest inputs.
        let width = 2 * maxD + 2
        var forward = [Int](repeating: -1, count: width)
        var reverse = [Int](repeating: -1, count: width)
        forward[offset + 1] = 0
        reverse[offset + 1] = 0
        let delta = n - m
        // With an odd delta the forward path detects the overlap, otherwise the reverse path.
        let front = delta % 2 != 0
        var k1Start = 0
        var k1End = 0
        var k2Start = 0
        var k2End = 0
        for d in 0..<maxD {
            var k1 = -d + k1Start
            while k1 <= d - k1End {
                let k1Offset = offset + k1
                var x1 =
                    (k1 == -d || (k1 != d && forward[k1Offset - 1] < forward[k1Offset + 1]))
                    ? forward[k1Offset + 1] : forward[k1Offset - 1] + 1
                var y1 = x1 - k1
                while x1 < n, y1 >= 0, y1 < m, a[aStart + x1] == b[bStart + y1] {
                    x1 += 1
                    y1 += 1
                }
                forward[k1Offset] = x1
                if x1 > n {
                    k1End += 2
                } else if y1 > m {
                    k1Start += 2
                } else if front {
                    let k2Offset = offset + delta - k1
                    if k2Offset >= 0, k2Offset < width, reverse[k2Offset] != -1, x1 >= n - reverse[k2Offset] {
                        split(oldRange, newRange, at: x1, y1)
                        return
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2Start
            while k2 <= d - k2End {
                let k2Offset = offset + k2
                var x2 =
                    (k2 == -d || (k2 != d && reverse[k2Offset - 1] < reverse[k2Offset + 1]))
                    ? reverse[k2Offset + 1] : reverse[k2Offset - 1] + 1
                var y2 = x2 - k2
                while x2 < n, y2 >= 0, y2 < m, a[aStart + n - x2 - 1] == b[bStart + m - y2 - 1] {
                    x2 += 1
                    y2 += 1
                }
                reverse[k2Offset] = x2
                if x2 > n {
                    k2End += 2
                } else if y2 > m {
                    k2Start += 2
                } else if !front {
                    let k1Offset = offset + delta - k2
                    if k1Offset >= 0, k1Offset < width, forward[k1Offset] != -1 {
                        let x1 = forward[k1Offset]
                        if x1 >= n - x2 {
                            split(oldRange, newRange, at: x1, offset + x1 - k1Offset)
                            return
                        }
                    }
                }
                k2 += 2
            }
        }
        // Nothing in common.
        emit(.removed, oldRange)
        emit(.added, newRange)
    }

    private mutating func split(_ oldRange: Range<Int>, _ newRange: Range<Int>, at x: Int, _ y: Int) {
        let x = min(max(x, 0), oldRange.count)
        let y = min(max(y, 0), newRange.count)
        // A split at either corner would diff the same ranges again.
        guard (x, y) != (0, 0), (x, y) != (oldRange.count, newRange.count) else {
            emit(.removed, oldRange)
            emit(.added, newRange)
            return
        }
        let aMiddle = oldRange.lowerBound + x
        let bMiddle = newRange.lowerBound + y
        diff(oldRange.lowerBound..<aMiddle, newRange.lowerBound..<bMiddle)
        diff(aMiddle..<oldRange.upperBound, bMiddle..<newRange.upperBound)
    }

    private mutating func emit(_ kind: Kind, _ range: Range<Int>) {
        guard !range.isEmpty else { return }
        let text = (kind == .added ? new[range] : old[range]).joined()
        switch (segments.last, kind) {
        case (.same(let previous)?, .same): segments[segments.count - 1] = .same(previous + text)
        case (.removed(let previous)?, .removed): segments[segments.count - 1] = .removed(previous + text)
        case (.added(let previous)?, .added): segments[segments.count - 1] = .added(previous + text)
        case (_, .same): segments.append(.same(text))
        case (_, .removed): segments.append(.removed(text))
        case (_, .added): segments.append(.added(text))
        }
    }
}
