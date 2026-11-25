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
            AIActionItems.formatted([
                AIActionItem(task: " Send the report. ", owner: nil, due: nil),
                AIActionItem(task: "Review\nit", owner: " ", due: "Tuesday"),
                AIActionItem(task: "", owner: "Lee", due: nil),
            ]) == "- Send the report.\n- Review it (due Tuesday)")
        #expect(
            AIActionItems.formatted([AIActionItem(task: "Book the room.", owner: "Lee", due: "tomorrow")])
                == "- Lee: Book the room (due tomorrow)")
        #expect(AIActionItems.formatted([]) == "No action items found.")
        #expect(AIActionItems.formatted([AIActionItem(task: " \n", owner: "Lee", due: nil)]) == "No action items found.")
        #expect(
            AIActionItems.cleaned([AIActionItem(task: "Call  back", owner: "Unknown", due: "N/A")])
                == [AIActionItem(task: "Call back", owner: nil, due: nil)])
    }

    @Test func checklistChipsComeOnlyFromStructuredFields() {
        // Plain bullet text is never parsed for owners or dates.
        let plain = ChatMessage(role: .assistant, text: "- Follow up: send the budget table\n- Standup at 9:15")
        #expect(plain.checklistItems.map(\.task) == ["Follow up: send the budget table", "Standup at 9:15"])
        #expect(plain.checklistItems.allSatisfy { $0.owner == nil && $0.due == nil })
        #expect(ChatMessage(role: .assistant, text: "No action items found.").checklistItems.isEmpty)

        let items = [AIActionItem(task: "Book the room", owner: "Lee", due: "tomorrow")]
        let structured = ChatMessage(
            role: .assistant, text: AIActionItems.formatted(items), actionItems: items)
        #expect(structured.checklistItems == items)
        #expect(ChatMessage(role: .assistant, text: "No action items found.", actionItems: []).checklistItems.isEmpty)
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
