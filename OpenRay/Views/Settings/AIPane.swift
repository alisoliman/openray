import AppKit
import SwiftUI

extension SettingsPane {
    static let ai = SettingsPane(
        id: "ai", title: "Apple Intelligence",
        subtitle: "Chat, AI Commands, agents and tools, on this Mac.",
        kind: .ai, symbol: "sparkles",
        keywords: "apple intelligence model on-device privacy chat writing agent quick fix tools private cloud compute dictation"
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
            AIModelSection(model: model)
            AIChatSettingsSection(model: model)
            AIWritingSettingsSection(model: model)
            AICommandsSettingsSection(model: model)
            AIToolsSettingsSection(model: model)
            Section("Privacy") {
                IconRow(
                    model.aiHub.effectiveModel == .privateCloud
                        ? "When the larger model is on, requests, attachments and tool results go to Apple's Private Cloud Compute, which keeps nothing."
                        : "Runs on Apple's on-device model. Nothing is sent to a server, and there's no cloud fallback.",
                    symbol: "lock.fill")
                IconRow(
                    "Clipboard, files, notes and the screen reach the model when you attach or @-mention them. An agent you give tools can also read your notes, clipboard history, snippets, quicklinks and file names without a mention.",
                    symbol: "paperclip")
                IconRow(
                    "A writing command uses the text selected in the app you opened OpenRay from: through Accessibility, or, when an app doesn't share it, by copying it and putting your clipboard back. Pasting a result borrows the clipboard the same way. The selection and where it came from stay in memory.",
                    symbol: "character.cursor.ibeam")
                IconRow("Chats in the launcher are kept in memory. Chats in the AI Chat window are saved on this Mac.", symbol: "note.text")
            }
        }
    }
}

/// On this Mac, or the opt-in larger model.
private struct AIModelSection: View {
    let model: LauncherModel

    var body: some View {
        let hub = model.aiHub
        let status = hub.privateCloudStatus
        Section {
            if !AIModelSelection.isBuildEnabled {
                LabeledContent {
                    Text("On this Mac").foregroundStyle(.secondary)
                } label: {
                    SettingRowLabel(title: "Model", detail: AIModelSelection.buildUnavailableReason)
                }
            } else {
                privateCloudRows(hub: hub, status: status)
            }
        } header: {
            Text("Model")
        }
    }

    @ViewBuilder private func privateCloudRows(hub: AIHub, status: AIPrivateCloudStatus?) -> some View {
            Toggle(isOn: Binding(
                get: { hub.settings.model == .privateCloud },
                set: { on in hub.updateSettings { $0.model = on ? .privateCloud : .onDevice } })
            ) {
                SettingRowLabel(
                    title: "Use the larger model (Private Cloud Compute)",
                    detail: "Off by default. Apple's larger model answers through Private Cloud Compute, within a usage limit. When it isn't available, requests stay on this Mac.")
            }
            .settingsSwitch()
            .disabled(status == nil)
            if hub.settings.model == .privateCloud || status != nil {
                LabeledContent("Larger model") {
                    StatusLabel(
                        tone: status?.isUsable == true ? .success : .warning,
                        text: status?.summary ?? "Not available in this version of macOS")
                }
                LabeledContent("Requests use") { Text(hub.effectiveModel.title).foregroundStyle(.secondary) }
            }
    }
}

/// The default agent, the agents themselves, and saved chats.
private struct AIChatSettingsSection: View {
    let model: LauncherModel
    @State private var confirmsDeleteAll = false

    var body: some View {
        let hub = model.aiHub
        Section {
            Picker(
                "Default agent",
                selection: Binding(
                    get: { hub.settings.defaultAgentID ?? Agent.assistantID },
                    set: { id in hub.updateSettings { $0.defaultAgentID = id == Agent.assistantID ? nil : id } })
            ) {
                ForEach(hub.agents) { Text($0.name).tag($0.id) }
            }
            .neutralMenus()
            ForEach(hub.agents.filter { !$0.isAssistant }) { agent in
                LabeledContent {
                    Button("Edit…") { hub.requestEditor(.agent(agent.id)) }
                } label: {
                    Label(agent.name, systemImage: agent.symbol)
                }
            }
            HStack {
                Button("New Agent…") { hub.requestEditor(.newAgent) }
                Spacer()
                Button("Open AI Chat") { hub.openChatWindow() }
            }
            Picker(
                "Keep chats",
                selection: Binding(
                    get: { hub.settings.chatRetention },
                    set: { value in hub.setChatRetention(value) })
            ) {
                ForEach(ChatRetention.allCases) { Text($0.title).tag($0) }
            }
            .neutralMenus()
            Toggle(isOn: Binding(get: { hub.settings.chatWindowOnTop }, set: { on in hub.updateSettings { $0.chatWindowOnTop = on } })) {
                SettingRowLabel(title: "Keep the chat window on top", detail: nil)
            }
            .settingsSwitch()
            LabeledContent {
                Button("Delete All Chats…", role: .destructive) { confirmsDeleteAll = true }
                    .disabled(hub.chatStore.chats.isEmpty)
            } label: {
                SettingRowLabel(
                    title: "\(hub.chatStore.chats.count.formatted()) saved chat\(hub.chatStore.chats.count == 1 ? "" : "s")",
                    detail: hub.chatStore.errorMessage ?? "Saved in the AIChats folder beside your library, and carried by library backups under Other Data. Deleted chats stay in Recently Deleted for \(ChatStore.recentlyDeletedDays) days.")
            }
        } header: {
            Text("Chat")
        }
        .alert("Delete all chats?", isPresented: $confirmsDeleteAll) {
            Button("Delete All", role: .destructive) { hub.deleteAllChats() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved chat is removed from this Mac, including Recently Deleted. This can't be undone.")
        }
    }
}

/// How writing results show and go back (work items 4 and 6): which commands mark their
/// changes, and what Return does.
private struct AIWritingSettingsSection: View {
    let model: LauncherModel

    /// The commands whose results rewrite the selected text, so their changes can be marked.
    /// Summaries, action items and answers aren't rewrites; marking them would mark everything.
    static let highlightableCommands: [(id: String, title: String)] =
        [AIAction.rewrite, .proofread, .shorten].map { (AIWritingCommandProvider.commandID(for: $0), $0.title) }
        + [(AICommand.changeTone.id, AICommand.changeTone.name)]

    var body: some View {
        let hub = model.aiHub
        Section {
            ForEach(Self.highlightableCommands, id: \.id) { command in
                Toggle(
                    isOn: Binding(
                        get: { hub.settings.highlightsChanges(for: command.id) },
                        set: { on in hub.updateSettings { $0.setHighlightsChanges(on, for: command.id) } })
                ) {
                    SettingRowLabel(title: command.title, detail: nil)
                }
                .settingsSwitch()
            }
            Picker(
                selection: Binding(get: { hub.settings.primaryAction }, set: { action in hub.updateSettings { $0.primaryAction = action } })
            ) {
                ForEach(AIPrimaryAction.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingRowLabel(
                    title: "Primary action",
                    detail:
                        "What Return does on a result. Paste Response pastes it over your selection in the app you came from and puts your clipboard back. ⌘Return always copies; with Copy Response, Paste Response is in ⌘K.")
            }
            .neutralMenus()
        } header: {
            Text("Writing commands")
        } footer: {
            Text("Marked changes show insertions in green and a red line where text was removed. Show Changes and Show Original are in ⌘K on any result.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// Quick Fix and custom AI Commands.
private struct AICommandsSettingsSection: View {
    let model: LauncherModel

    var body: some View {
        let hub = model.aiHub
        Section {
            Picker(
                "Quick Fix runs",
                selection: Binding(get: { hub.settings.quickFixCommandID }, set: { id in hub.updateSettings { $0.quickFixCommandID = id } })
            ) {
                ForEach(hub.quickFixChoices, id: \.id) { Text($0.title).tag($0.id) }
            }
            .neutralMenus()
            Toggle(
                isOn: Binding(
                    get: { hub.settings.quickFixPrefersSelection },
                    set: { on in hub.updateSettings { $0.quickFixPrefersSelection = on } })
            ) {
                SettingRowLabel(
                    title: "Prefer selection",
                    detail: "Quick Fix works on the selected text. Off, or with nothing selected, it works on the whole text field.")
            }
            .settingsSwitch()
            if let quickFix = model.bindableCommands.first(where: { $0.id == AICommandProvider.quickFixID }) {
                CommandBindingRow(model: model, command: quickFix)
            }
            ForEach(hub.aiCommands.filter { !$0.isBuiltIn }) { command in
                LabeledContent {
                    Button("Edit…") { hub.requestEditor(.command(command.id)) }
                } label: {
                    Label(command.name, systemImage: command.symbol)
                }
            }
            HStack {
                Button("New AI Command…") { hub.requestEditor(.newCommand) }
                Spacer()
                Button("Import…") { AICommandFiles.importCommands(model) }
                Button("Export…") { AICommandFiles.exportCommands(model) }
                    .disabled(!hub.aiCommands.contains { !$0.isBuiltIn })
            }
        } header: {
            Text("AI Commands")
        } footer: {
            Text("Quick Fix replaces text in place in any app, with no window, after checking the text hasn't changed. Give it a shortcut above. An AI Command set to Replace Selection works the same way.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

/// What tools may do without asking, plus screen context and dictation.
private struct AIToolsSettingsSection: View {
    let model: LauncherModel

    var body: some View {
        let hub = model.aiHub
        Section {
            ForEach(hub.toolExtensions) { item in
                ForEach(item.tools) { tool in
                    if tool.isAction {
                        LabeledContent {
                            Text("Asks every time").foregroundStyle(.secondary)
                        } label: {
                            SettingRowLabel(title: "\(tool.title)  ·  @\(item.id)", detail: "Changes your library, so each call needs your OK")
                        }
                    } else {
                        Picker(
                            selection: Binding(
                                get: { hub.settings.toolPermissions[tool.id] ?? .auto },
                                set: { value in hub.updateSettings { $0.toolPermissions[tool.id] = value } })
                        ) {
                            ForEach(AIToolPermission.choices(for: tool)) { Text($0.title).tag($0) }
                        } label: {
                            SettingRowLabel(title: "\(tool.title)  ·  @\(item.id)", detail: nil)
                        }
                        .neutralMenus()
                    }
                }
            }
            Toggle(isOn: Binding(get: { hub.settings.screenContextEnabled }, set: { on in hub.updateSettings { $0.screenContextEnabled = on } })) {
                SettingRowLabel(
                    title: "Allow screen context",
                    detail: "Attach the frontmost window or the screen to a chat. macOS asks for Screen Recording permission the first time.")
            }
            .settingsSwitch()
            Toggle(isOn: Binding(get: { hub.settings.dictationEnabled }, set: { on in hub.updateSettings { $0.dictationEnabled = on } })) {
                SettingRowLabel(
                    title: "Dictation (⌃M)", detail: hub.dictation.unavailableReason ?? "Transcribed on this Mac with the Speech framework.")
            }
            .settingsSwitch()
        } header: {
            Text("Tools and context")
        } footer: {
            Text("For tools that only read: Ask asks first, Auto and Always read without asking. Tools that change anything ask every time and show what they'll write. Type @ and a name in chat to use a tool; an agent's tools can read without a mention.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}
