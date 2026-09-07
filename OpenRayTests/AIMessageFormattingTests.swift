import Foundation
import SwiftUI
import Testing

@testable import OpenRay

struct AIMessageFormattingTests {
    @Test func rendersEmphasisAndListsWithoutLosingParagraphs() {
        let value = AIMessageFormatting.attributed(
            "## Common nouns\n\n1. **Dog**: an animal.\n2. *Book*: pages.\n\n- More examples\n  - A nested item")
        #expect(
            String(value.characters)
                == "Common nouns\n\n1. Dog: an animal.\n2. Book: pages.\n\n• More examples\n  • A nested item")
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    }

    @Test func generatedLinksAndImagesHaveNoResourceAttributes() {
        let value = AIMessageFormatting.attributed(
            "[Website](https://example.com) [File](file:///tmp/example) [Script](javascript:alert(1)) ![Tracker](https://example.com/pixel.png)"
        )
        #expect(String(value.characters) == "Website File Script Tracker")
        #expect(value.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
    }

    @Test func codeBlocksPreserveLiteralSyntaxAndUnclosedStreamingContent() {
        let value = AIMessageFormatting.attributed("Example:\n```swift\nlet stars = \"**literal**\"\n\nprint(stars)")
        #expect(String(value.characters) == "Example:\nlet stars = \"**literal**\"\n\nprint(stars)")
        #expect(value.runs.contains { $0.font != nil })
        let completed = AIMessageFormatting.attributed("```\n**literal**\n```\n\n**Bold**")
        #expect(String(completed.characters) == "**literal**\n\nBold")
        #expect(String(AIMessageFormatting.attributed("**unfinished").characters) == "**unfinished")
        let inline = AIMessageFormatting.attributed("```print(\"hello\")```")
        #expect(String(inline.characters) == "print(\"hello\")")
        #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        #expect(String(AIMessageFormatting.attributed("```").characters) == "```")
    }

    @Test func actionItemsAlwaysHaveDistinctListRows() {
        #expect(
            AIActionItemsResult.formatted([" Send the report. ", "Review\nit Tuesday.", ""])
                == "- Send the report.\n- Review it Tuesday.")
        #expect(AIActionItemsResult.formatted([]) == "No action items found.")
        #expect(AIActionItemsResult.formatted([" \n"]) == "No action items found.")
    }

    @Test func proofreadingRetainsSourceLayoutWhenNoWordsOrPunctuationChanged() {
        let source = "First paragraph.\n\nSecond paragraph."
        #expect(
            AIProofreadingResult.preservingUnchangedPassage("First paragraph. Second paragraph.", original: source)
                == source)
        #expect(
            AIProofreadingResult.preservingUnchangedPassage("First paragraph.\n\nSecond paragraph!", original: source)
                == "First paragraph.\n\nSecond paragraph!")
    }
}
