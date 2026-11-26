import SwiftUI

extension LauncherModel {
    /// Slice 7's ⌘K entries in the AI view: tool approvals, Continue in Chat Window (⌘J),
    /// agents and screen context. `aiActions()` lists them after the attachment entries.
    func slice7AIActions() -> [ActionEntry] {
        let hub = aiHub
        var entries: [ActionEntry] = []
        if let approval = ai.environment.toolBroker?.pendingApprovals.first {
            let broker = ai.environment.toolBroker
            entries.append(
                ActionEntry(id: "tool.allow", title: "Allow \(approval.title)", symbol: "checkmark.circle", group: .item) {
                    broker?.resolve(approval.id, .allow)
                })
            entries.append(
                ActionEntry(id: "tool.always", title: "Always Allow \(approval.title)", symbol: "checkmark.seal", group: .item) {
                    broker?.resolve(approval.id, .alwaysAllow)
                })
            entries.append(
                ActionEntry(id: "tool.deny", title: "Don't Allow", symbol: "xmark.circle", group: .item, isDestructive: true) {
                    broker?.resolve(approval.id, .deny)
                })
        }
        if !ai.isGenerating {
            let hasReply = ai.messages.contains { $0.role == .assistant && !$0.text.isEmpty }
            entries.append(
                ActionEntry(
                    id: "chatWindow", title: hasReply ? "Continue in Chat Window" : "Open Chat Window",
                    symbol: "macwindow.on.rectangle", shortcut: .command("J"), key: "j", modifiers: .command, group: .organize
                ) { [weak self] in
                    guard let self else { return }
                    if !(hasReply && self.aiHub.continueInChat()) { self.aiHub.openChatWindow() }
                })
        }
        if ai.action == .chat, ai.command == nil, !ai.isGenerating {
            let current = ai.agent?.id ?? Agent.assistantID
            for agent in hub.agents.prefix(8) {
                entries.append(
                    ActionEntry(
                        id: "agent.\(agent.id.uuidString)", title: "Chat with \(agent.name)",
                        symbol: agent.id == current ? "checkmark" : agent.symbol, group: .organize, section: "Agent"
                    ) { [weak self] in
                        self?.ai.selectAgent(agent)
                        self?.focusRequest += 1
                    })
            }
            if hub.settings.screenContextEnabled {
                entries.append(
                    ActionEntry(id: "attachWindow", title: "Attach Focused Window", symbol: "macwindow", group: .organize) {
                        [weak self] in
                        guard let self else { return }
                        let pid = self.previousApplication?.processIdentifier
                        Task { await self.aiHub.attachScreen(.focusedWindow(processID: pid), to: self.ai) }
                    })
                entries.append(
                    ActionEntry(id: "attachScreen", title: "Attach Screen", symbol: "rectangle.on.rectangle", group: .organize) {
                        [weak self] in
                        guard let self else { return }
                        Task { await self.aiHub.attachScreen(.entireScreen, to: self.ai) }
                    })
            }
        }
        return entries
    }
}
