import Foundation
import SwiftUI

/// Native text rendering for model-generated Markdown. No HTML renderer, remote
/// images, or active links: generated content cannot load or open a resource.
enum AIMessageFormatting {
    static func attributed(_ source: String) -> AttributedString {
        var result = AttributedString()
        var fence: String?
        var needsNewline = false

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let currentFence = fence {
                if trimmed.hasPrefix(currentFence), trimmed.allSatisfy({ $0 == currentFence.first }) {
                    fence = nil
                    continue
                }
                var code = AttributedString(line)
                code.font = .system(size: 12, design: .monospaced)
                append(code, to: &result, needsNewline: &needsNewline)
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let markerRun = trimmed.prefix(while: { $0 == marker })
                // A same-line code span is inline content, not a fence opener.
                if markerRun.count >= 3, !trimmed.dropFirst(markerRun.count).contains(marker) {
                    fence = String(markerRun)
                    continue
                }
            }

            let indentation = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let headingDepth = trimmed.prefix(while: { $0 == "#" }).count
            var content = line
            var isHeading = false
            if (1...6).contains(headingDepth), trimmed.dropFirst(headingDepth).first == " " {
                content = String(trimmed.dropFirst(headingDepth + 1))
                isHeading = true
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                content = indentation + "• " + trimmed.dropFirst(2)
            } else if trimmed.hasPrefix("> ") {
                content = indentation + "│ " + trimmed.dropFirst(2)
            }
            var text =
                (try? AttributedString(
                    markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(content)
            text.link = nil
            text.imageURL = nil
            if isHeading { text.font = .system(size: 15, weight: .semibold) }
            append(text, to: &result, needsNewline: &needsNewline)
        }
        return result.characters.isEmpty && !source.isEmpty ? AttributedString(source) : result
    }

    private static func append(
        _ text: AttributedString, to result: inout AttributedString, needsNewline: inout Bool
    ) {
        if needsNewline { result.append(AttributedString("\n")) }
        result.append(text)
        needsNewline = true
    }
}
