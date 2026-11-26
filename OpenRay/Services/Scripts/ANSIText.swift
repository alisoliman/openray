import Foundation

/// A color an ANSI escape code asks for. The view maps these onto OpenRay's palette.
enum ANSIColor: Hashable, Sendable {
    /// 30–37 and 40–47: black, red, green, yellow, blue, magenta, cyan, white.
    case standard(Int)
    /// 90–97 and 100–107.
    case bright(Int)
    /// `38;5;n` / `48;5;n`: the 256-color palette.
    case palette(Int)
    /// `38;2;r;g;b` / `48;2;r;g;b`.
    case rgb(UInt8, UInt8, UInt8)

    /// The color as RGB, 0–255 each, with the 256-color cube and gray ramp resolved. Standard and
    /// bright colors return nil: the view picks those from its appearance-aware palette.
    var rgbComponents: (red: UInt8, green: UInt8, blue: UInt8)? {
        switch self {
        case .standard, .bright: return nil
        case .rgb(let red, let green, let blue): return (red, green, blue)
        case .palette(let index):
            switch index {
            case 0..<16: return nil
            case 16..<232:
                let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
                let value = index - 16
                return (levels[value / 36], levels[(value / 6) % 6], levels[value % 6])
            default:
                let gray = UInt8(clamping: 8 + (index - 232) * 10)
                return (gray, gray, gray)
            }
        }
    }

    /// Palette entries 0–15 are the standard and bright colors.
    var normalized: ANSIColor {
        if case .palette(let index) = self, index < 16 { return index < 8 ? .standard(index) : .bright(index - 8) }
        return self
    }
}

struct ANSIStyle: Hashable, Sendable {
    var foreground: ANSIColor?
    var background: ANSIColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var strikethrough = false
    var inverse = false

    static let plain = ANSIStyle()
}

/// A run of text in one style.
struct ANSISpan: Hashable, Sendable {
    var text: String
    var style: ANSIStyle
}

/// Reads terminal output with ANSI escape codes: SGR colors and styles become spans; every other
/// escape sequence and control character is dropped. A carriage return without a newline starts
/// its line over, as a terminal's progress lines do.
enum ANSIText {
    static func parse(_ text: String) -> [ANSISpan] {
        var spans: [ANSISpan] = []
        var style = ANSIStyle.plain
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            if let last = spans.last, last.style == style {
                spans[spans.count - 1].text += current
            } else {
                spans.append(ANSISpan(text: current, style: style))
            }
            current = ""
        }
        let scalars = Array(overwritingCarriageReturns(text).unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                index += 1
                guard index < scalars.count else { break }
                switch scalars[index] {
                case "[":
                    // CSI: parameters, intermediates, one final byte.
                    index += 1
                    var parameters = ""
                    while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) {
                        parameters.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    guard index < scalars.count else { break }
                    let final = scalars[index]
                    index += 1
                    if final == "m" {
                        flush()
                        apply(sgr: parameters, to: &style)
                    }
                case "]":
                    // OSC: up to BEL or ESC \.
                    index += 1
                    while index < scalars.count {
                        if scalars[index] == "\u{07}" {
                            index += 1
                            break
                        }
                        if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                case "(", ")", "#", "%":
                    index += 2
                default:
                    index += 1
                }
                continue
            }
            if scalar == "\n" || scalar == "\t" || scalar.value >= 0x20 && scalar.value != 0x7F {
                current.unicodeScalars.append(scalar)
            }
            index += 1
        }
        flush()
        return spans
    }

    /// The text without escape codes.
    static func strip(_ text: String) -> String { parse(text).map(\.text).joined() }

    /// Applies one SGR parameter list, such as `1;31;42` or `38;2;255;0;0`.
    static func apply(sgr parameters: String, to style: inout ANSIStyle) {
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: false) }
            .map { Int($0) ?? 0 }
        var index = 0
        let list = codes.isEmpty ? [0] : codes
        while index < list.count {
            let code = list[index]
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4, 21: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 22:
                style.bold = false
                style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .standard(code - 30)
            case 39: style.foreground = nil
            case 40...47: style.background = .standard(code - 40)
            case 49: style.background = nil
            case 90...97: style.foreground = .bright(code - 90)
            case 100...107: style.background = .bright(code - 100)
            case 38, 48:
                var color: ANSIColor?
                if index + 2 < list.count, list[index + 1] == 5 {
                    color = ANSIColor.palette(max(0, min(255, list[index + 2]))).normalized
                    index += 2
                } else if index + 4 < list.count, list[index + 1] == 2 {
                    color = .rgb(
                        UInt8(clamping: list[index + 2]), UInt8(clamping: list[index + 3]), UInt8(clamping: list[index + 4]))
                    index += 4
                }
                if code == 38 { style.foreground = color } else { style.background = color }
            default: break
            }
            index += 1
        }
    }

    /// CRLF becomes LF; otherwise a line keeps only what follows its last carriage return.
    static func overwritingCarriageReturns(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let last = line.lastIndex(of: "\r") else { return String(line) }
            return String(line[line.index(after: last)...])
        }.joined(separator: "\n")
    }

    /// Splits bytes into the longest prefix that ends on a UTF-8 character boundary and the
    /// incomplete character after it, so streamed output never shows half a character.
    static func splitCompleteUTF8(_ data: Data) -> (complete: Data, remainder: Data) {
        let bytes = [UInt8](data)
        var index = bytes.count - 1
        var steps = 0
        while index >= 0, steps < 4 {
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 {
                let needed = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                if bytes.count - index < needed {
                    return (Data(bytes[..<index]), Data(bytes[index...]))
                }
                return (Data(bytes), Data())
            }
            index -= 1
            steps += 1
        }
        return (Data(bytes), Data())
    }
}
