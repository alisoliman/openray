import SwiftUI

/// The agent chat talks to, as a header menu. The panel and the chat window both show it.
struct AgentMenu: View {
    let chat: AIChatModel
    let agents: [Agent]
    var didChoose: () -> Void = {}

    var body: some View {
        let current = chat.agent ?? .assistant
        Menu {
            ForEach(agents) { agent in
                Button {
                    chat.selectAgent(agent)
                    didChoose()
                } label: {
                    Label(agent.name, systemImage: agent.id == current.id ? "checkmark" : agent.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.symbol).font(.system(size: 11))
                Text(current.name).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text2)
            .padding(.horizontal, 9).frame(height: 24)
            .background(OR.Color.fill1, in: .capsule)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .disabled(chat.isGenerating)
        .help("Choose an agent. You can also type / and its name.")
        .accessibilityLabel("Agent: \(current.name)")
    }
}

/// Completions above the composer: agents while `/name` is typed, tools while `@name` is.
struct ChatSuggestions: View {
    let chat: AIChatModel
    let agents: [Agent]
    let extensions: [AIToolExtension]
    var didChoose: () -> Void = {}

    var body: some View {
        let agentMatches = AgentSwitch.suggestions(for: chat.draft, agents: agents)
        let toolMatches = AIMentionParser.completions(for: chat.draft, extensions: extensions)
        if !agentMatches.isEmpty || !toolMatches.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(agentMatches) { agent in
                        chip(agent.name, symbol: agent.symbol, prefix: "/") {
                            chat.selectAgent(agent)
                            chat.draft = ""
                        }
                    }
                    ForEach(toolMatches) { item in
                        chip(item.title, symbol: item.symbol, prefix: "@") {
                            if let at = chat.draft.lastIndex(of: "@") {
                                chat.draft = String(chat.draft[..<at]) + item.mention + " "
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 34)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Suggestions")
        }
    }

    private func chip(_ title: String, symbol: String, prefix: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            didChoose()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(prefix + title)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text)
            .padding(.horizontal, 9).frame(height: 26)
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.chip, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(HoverButtonStyle(radius: OR.Radius.chip))
    }
}

/// A card for each tool call waiting for the person: Allow, Always Allow, or Don't Allow.
struct ToolApprovalCards: View {
    let broker: AIToolBroker

    var body: some View {
        ForEach(broker.pendingApprovals) { approval in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: approval.symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OR.Color.text2).accessibilityHidden(true)
                    Text(approval.isAction ? "Allow this action?" : "Allow reading your data?")
                        .font(OR.Font.headline).foregroundStyle(OR.Color.text)
                }
                Text(approval.detail).font(OR.Font.body).foregroundStyle(OR.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !approval.fields.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(approval.fields.enumerated()), id: \.offset) { _, field in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(field.label).font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                                // The whole value, scrollable when long.
                                ScrollView {
                                    Text(field.value).font(.system(size: 12.5)).foregroundStyle(OR.Color.text)
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 160)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OR.Color.fill2, in: .rect(cornerRadius: OR.Radius.chip, style: .continuous))
                }
                Text(approval.isAction ? "\(approval.title) · asks every time" : "\(approval.title) · runs on this Mac")
                    .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                HStack(spacing: 8) {
                    Button("Allow") { broker.resolve(approval.id, .allow) }.buttonStyle(.orPrimary)
                    if approval.offersAlways {
                        Button("Always Allow") { broker.resolve(approval.id, .alwaysAllow) }.buttonStyle(.orSecondary)
                    }
                    Spacer(minLength: 0)
                    Button("Don't Allow") { broker.resolve(approval.id, .deny) }.buttonStyle(.orGhost)
                }
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: OR.Radius.card, style: .continuous).strokeBorder(OR.Color.separator) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Approval needed: \(approval.detail)")
        }
    }
}

/// What the tools did in this conversation, one quiet line each.
struct ToolActivityList: View {
    let broker: AIToolBroker

    var body: some View {
        ForEach(broker.activity.suffix(4)) { item in
            Label {
                Text(line(item)).lineLimit(2)
            } icon: {
                Image(systemName: symbol(item.outcome))
            }
            .labelStyle(TightLabelStyle()).font(OR.Font.caption).foregroundStyle(OR.Color.text2)
        }
    }

    private func line(_ item: AIToolActivity) -> String {
        switch item.outcome {
        case .ran: item.detail
        case .declined: "\(item.detail) — not allowed"
        case .blocked(let reason), .failed(let reason): "\(item.detail) — \(reason)"
        }
    }

    private func symbol(_ outcome: AIToolActivity.Outcome) -> String {
        switch outcome {
        case .ran: "checkmark.circle"
        case .declined: "hand.raised"
        case .blocked, .failed: "exclamationmark.triangle"
        }
    }
}

/// ⌃M dictation into a conversation's draft, when turned on in Settings.
struct DictationButton: View {
    let dictation: any AIDictating
    let chat: AIChatModel
    @State private var isListening = false
    @State private var base = ""

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isListening ? "mic.fill" : "mic")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isListening ? OR.Color.danger : OR.Color.text2)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(HoverButtonStyle(radius: OR.Radius.chip))
        .keyboardShortcut("m", modifiers: .control)
        .help(dictation.unavailableReason ?? (isListening ? "Stop dictation (⌃M)" : "Dictate (⌃M)"))
        .accessibilityLabel(isListening ? "Stop dictation" : "Dictate")
        .onDisappear { if isListening { dictation.stop() } }
    }

    private func toggle() {
        if isListening {
            dictation.stop()
            isListening = false
            return
        }
        if let reason = dictation.unavailableReason {
            chat.report(reason)
            return
        }
        base = chat.draft.isEmpty || chat.draft.hasSuffix(" ") ? chat.draft : chat.draft + " "
        isListening = true
        // Words go only to the conversation dictation started in.
        let token = chat.conversationToken
        Task {
            do {
                try await dictation.start { text in
                    guard chat.conversationToken == token else {
                        dictation.stop()
                        isListening = false
                        return
                    }
                    chat.draft = base + text
                }
            } catch {
                isListening = false
                chat.report(error.localizedDescription)
            }
        }
    }
}
