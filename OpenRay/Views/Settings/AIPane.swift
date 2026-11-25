import AppKit
import SwiftUI

extension SettingsPane {
    static let ai = SettingsPane(
        id: "ai", title: "Apple Intelligence",
        subtitle: "Ask AI and writing commands, on this Mac.",
        kind: .ai, symbol: "sparkles",
        keywords: "apple intelligence model on-device privacy chat writing"
    ) { model, _ in AnyView(AIPane(model: model)) }
}

struct AIPane: View {
    let model: LauncherModel

    var body: some View {
        let availability = model.ai.availability
        SettingsPaneScaffold(pane: .ai) {
            Section {
                LabeledContent {
                    StatusLabel(tone: availability.isAvailable ? .success : availability == .preparing ? .working : .warning, text: availability.shortStatus)
                } label: {
                    SettingRowLabel(title: availability.headline, detail: availability.detail)
                }
                ForEach(availability.requirements) { requirement in
                    LabeledContent {
                        Image(
                            systemName: requirement.state == .met
                                ? "checkmark.circle.fill" : requirement.state == .waiting ? "clock" : "exclamationmark.circle"
                        )
                        .foregroundStyle(
                            requirement.state == .met
                                ? OR.Color.success : requirement.state == .blocked ? OR.Color.warning : .secondary)
                            .accessibilityHidden(true)
                    } label: {
                        SettingRowLabel(title: requirement.title, detail: requirement.note)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(
                        requirement.state == .met ? "Done" : requirement.state == .waiting ? "In progress" : "Needed")
                }
                if !availability.isAvailable {
                    HStack {
                        Spacer()
                        Button("Check Again") { model.ai.refreshAvailability() }
                        Button("Open Apple Intelligence Settings") { AppleIntelligenceSettings.open() }
                            .buttonStyle(.borderedProminent).tint(OR.Color.accentButton)
                    }
                }
            }
            Section("Privacy") {
                IconRow("Runs on Apple's on-device model. Nothing is sent to a server, and there's no cloud fallback.", symbol: "lock.fill")
                IconRow("Clipboard and selected text reach the model only when you attach them or start a writing command.", symbol: "paperclip")
                IconRow("Chats are kept in memory. Save as Note is the only way a response is stored.", symbol: "note.text")
            }
        }
    }
}
