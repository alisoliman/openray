import AppKit
import SwiftUI

/// AI inside the panel: chat, writing commands that transform a selection,
/// and a checklist when Apple Intelligence isn't ready.
struct AIView: View {
    @Bindable var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            Group {
                if !model.ai.isReady {
                    AIUnavailableView(model: model)
                } else if model.ai.action == .chat {
                    ChatBody(model: model)
                } else {
                    TransformBody(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.ai.isReady, model.ai.action != .chat, !model.ai.messages.isEmpty {
                FollowUpComposer(model: model)
            }
            bar
        }
        .overlay(alignment: .topTrailing) { attachmentPreview }
        .onAppear { model.ai.refreshAvailability() }
        // The bar says “Writing on this Mac…” while a reply is written, so an earlier
        // problem shouldn't keep covering it. Toasts expire on their own.
        .onChange(of: model.ai.isGenerating) { _, generating in
            if generating, let style = model.feedback?.style, style == .error || style == .warning { model.feedback = nil }
        }
    }

    /// ↩ from the one-line follow-up field. ⌘↩ and ⌥↩ reach the field's own paste and tertiary
    /// actions (Copy, Paste Formatted); ⇧↩ does nothing in a one-line field, and a held ↩ never
    /// sends and then pastes.
    static func submitFromField(_ model: LauncherModel) {
        if let event = NSApp.currentEvent, event.type == .keyDown {
            guard !event.isARepeat, event.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
        }
        model.submitAI()
    }

    // MARK: Header

    /// The command's name, and where Raycast names the model, “On-device” (work item 4).
    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            ScopeToken(
                kind: .ai, symbol: model.ai.symbol, title: model.ai.title,
                onRemove: { model.leaveAI() })
            Spacer(minLength: 0)
            if model.ai.availability.isAvailable {
                if model.ai.action == .chat, model.ai.command == nil {
                    AgentMenu(chat: model.ai, agents: model.aiHub.agents) { model.focusRequest += 1 }
                }
                HStack(spacing: 6) {
                    Circle().fill(OR.Color.success).frame(width: 6, height: 6)
                    Text(model.ai.action == .chat ? "On this Mac" : modelName)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text2)
                .padding(.horizontal, 9).frame(height: 24)
                .background(OR.Color.fill1, in: .capsule)
                .help(
                    modelName == "On-device"
                        ? "Apple's on-device model. Nothing is sent to a server." : "Apple's Private Cloud Compute model.")
                if model.ai.action == .chat {
                    Button {
                        model.newAIConversation()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.pencil").font(.system(size: 12))
                            Text("New Chat")
                            KeyCaps(["⌘", "N"], size: .small)
                        }
                    }
                    .buttonStyle(.orGhost)
                    .accessibilityHint(KeyShortcut(["⌘", "N"]).spoken)
                    .disabled(model.ai.isGenerating || model.ai.messages.isEmpty)
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 14)
        .frame(height: OR.Metric.field)
        .onChange(of: model.ai.attachments.first?.id) { model.showsAttachmentPreview = false }
        .onChange(of: model.showsAttachmentPreview) { _, isShown in
            // Hand focus back to the field so Esc and Return keep their routing.
            if !isShown { model.focusRequest += 1 }
        }
        .onChange(of: model.showActions || model.showShortcuts) { _, covered in
            if covered { model.showsAttachmentPreview = false }
        }
    }

    /// The model a writing run uses: writing commands always run on this Mac; an AI Command uses
    /// the larger model when it's turned on and answering.
    private var modelName: String {
        model.ai.command != nil && model.aiHub.effectiveModel == .privateCloud ? "Private Cloud Compute" : "On-device"
    }

    /// The attached text in full, drawn inside the panel like ⌘K. A native popover
    /// would take key, and the launcher closes when it loses key. Esc or a click
    /// anywhere else closes it.
    @ViewBuilder private var attachmentPreview: some View {
        ZStack(alignment: .topTrailing) {
            if model.showsAttachmentPreview, model.ai.action != .chat, let attachment = model.ai.attachments.first {
                Color.clear.contentShape(.rect)
                    .onTapGesture { model.showsAttachmentPreview = false }
                    .accessibilityHidden(true)
                AttachmentPopover(attachment: attachment) {
                    model.showsAttachmentPreview = false
                    model.ai.removeAttachment(attachment.id)
                }
                .popoverSurface()
                .padding(.top, OR.Metric.field - 6).padding(.trailing, 10)
                .transition(.opacity)
            }
        }
        .animation(OR.Motion.resolve(OR.Motion.quick, reduceMotion: reduceMotion), value: model.showsAttachmentPreview)
    }

    // MARK: Bar

    @ViewBuilder private var bar: some View {
        let feedback: Feedback? =
            model.feedback ?? model.ai.errorMessage.map { .error($0) }
            ?? (model.ai.isGenerating ? .working(model.ai.isCancelling ? "Stopping…" : "Writing on this Mac…") : nil)
            ?? model.readingSelectionFrom.map { .working("Reading the selection in \($0)…") }
        ActionBar(
            feedback: feedback, confirmation: model.confirmation, confirmationInstance: model.confirmationInstanceID,
            context: { context },
            actions: { actions },
            onCancelConfirmation: { model.confirmation = nil },
            onConfirm: { if let confirmation = model.confirmation { model.confirm(confirmation) } },
            onConfirmationShown: model.confirmationDidAppear, onApprove: model.approveConfirmation)
    }

    @ViewBuilder private var context: some View {
        if !model.ai.isReady {
            Image(systemName: "info.circle").font(.system(size: 12)).accessibilityHidden(true)
            Text("Everything else in OpenRay works without AI")
        } else if model.ai.action != .chat, model.ai.latestResponse != nil {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(OR.Color.success)
                .accessibilityHidden(true)
            Text("Done on this Mac").fontWeight(.medium)
        } else {
            Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            Text(model.ai.action == .chat ? "Not saved · Review answers before using them" : "Runs on this Mac · Nothing is saved")
        }
    }

    @ViewBuilder private var actions: some View {
        if !model.ai.isReady {
            ActionBarButton(title: "Back", keys: ["esc"], style: .ghost) { model.goBack() }
        } else if model.ai.isGenerating {
            ActionBarButton(title: "Stop", keys: ["⌘", "."]) { model.ai.cancel() }
                .disabled(model.ai.isCancelling)
        } else if model.ai.action == .chat {
            ActionBarButton(title: "Send", keys: ["↩"]) { model.ai.send() }
                .disabled(!model.ai.canSend)
                .accessibilityIdentifier("ai.send")
            ActionBarDivider()
            ActionBarButton(title: "Actions", keys: ["⌘", "K"], style: .ghost, isOn: model.showActions) {
                model.showActions.toggle()
            }
        } else if model.ai.messages.last?.role == .assistant {
            // ↩ follows the field: a follow-up asks for changes, an empty field uses the result.
            if model.ai.isRevising {
                ActionBarButton(title: "Ask", keys: ["↩"], style: .accent) { model.ai.send() }
                    .disabled(!model.ai.canSend)
                    .accessibilityIdentifier("ai.send")
            } else if model.canAcceptAIResponse {
                ActionBarButton(title: model.aiAcceptTitle, keys: ["↩"], style: .accent) {
                    model.acceptAIResponse()
                }
                .accessibilityIdentifier("ai.accept")
                ActionBarButton(title: model.aiSecondaryTitle, keys: ["⌘", "↩"], style: .ghost) {
                    model.performAISecondary()
                }
            } else if model.aiResultIsUnchanged {
                ActionBarButton(title: "Done", keys: ["↩"]) { model.leaveAI() }
            } else if model.ai.latestResponse == nil {
                ActionBarButton(title: "Try Again", keys: ["↩"]) { model.ai.retry() }
            }
            ActionBarDivider()
            ActionBarButton(title: "Actions", keys: ["⌘", "K"], style: .ghost, isOn: model.showActions) {
                model.showActions.toggle()
            }
        } else if model.readingSelectionFrom == nil {
            ActionBarButton(title: model.ai.runTitle, keys: ["↩"], style: .accent) { model.ai.send() }
                .disabled(!model.ai.canSend)
                .accessibilityIdentifier("ai.send")
            ActionBarDivider()
            ActionBarButton(title: "Actions", keys: ["⌘", "K"], style: .ghost, isOn: model.showActions) {
                model.showActions.toggle()
            }
        }
    }
}

// MARK: - Chat

/// What a conversation's reply buttons do, so the panel and the chat window share the views.
struct ChatMessageActions {
    var copy: (ChatMessage) -> Void
    /// The paste button's title for a reply (the latest one when the flag is set), or nil for none.
    var pasteTitle: (ChatMessage, Bool) -> String?
    var paste: (ChatMessage, Bool) -> Void
    var saveNote: (ChatMessage) -> Void
    var retry: () -> Void
    /// Continues from a reply in a new chat. Only saved chats can branch.
    var branch: ((ChatMessage) -> Void)? = nil
}

private struct ChatBody: View {
    @Bindable var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscript(chat: model.ai, actions: actions) { emptyChat }
            ChatSuggestions(chat: model.ai, agents: model.aiHub.agents, extensions: model.aiHub.toolExtensions) {
                model.focusRequest += 1
            }
            ChatComposer(model: model)
        }
    }

    private var actions: ChatMessageActions {
        ChatMessageActions(
            copy: { model.copy($0.text) },
            pasteTitle: { _, isLatest in
                if isLatest { return model.aiResultIsUnchanged ? nil : model.aiPasteTitle }
                // Earlier replies paste as they are; nothing about them replaces a selection.
                return model.canPasteDirectly || !model.clipboard.usesGeneralPasteboard
                    ? "Paste to \(model.targetAppName)" : "Copy · ⌘V in \(model.targetAppName)"
            },
            paste: { message, isLatest in if isLatest { model.pasteAIResponse() } else { model.paste(message.text) } },
            saveNote: { model.saveResponseAsNote($0) },
            retry: { model.ai.retry() })
    }

    private var emptyChat: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                kind: .ai, title: "Ask anything",
                detail: "Brainstorm, draft or work through a question. Apple's on-device model answers here. Type @ to use your notes, clipboard or files, or / to pick an agent."
            ) {
                ForEach(
                    [
                        ("Draft a reply", "Help me draft a thoughtful reply to this message: "),
                        ("Brainstorm", "Help me brainstorm ideas for "),
                        ("Explain simply", "Explain this in simple terms: "),
                    ], id: \.0
                ) { suggestion in
                    Button(suggestion.0) {
                        model.ai.useText(suggestion.1)
                        model.focusRequest += 1
                    }
                    .buttonStyle(.orSecondary)
                }
            }
        }
        .padding(.top, 8)
    }
}

/// A conversation's messages, with its notices, tool activity and approval cards, kept
/// scrolled to the end. The panel and the chat window both draw it.
struct ChatTranscript<Empty: View>: View {
    let chat: AIChatModel
    let actions: ChatMessageActions
    @ViewBuilder var empty: Empty

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if chat.messages.isEmpty, chat.environment.toolBroker?.pendingApprovals.isEmpty != false {
                    empty
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if chat.summarizedMessageCount > 0 {
                            Label("Earlier messages are summarized to fit the on-device model.", systemImage: "text.badge.minus")
                                .labelStyle(TightLabelStyle()).font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                        }
                        ForEach(chat.messages) { message in
                            ChatMessageView(
                                chat: chat, message: message, isLatest: message.id == chat.messages.last?.id, actions: actions)
                        }
                        if let broker = chat.environment.toolBroker {
                            ToolActivityList(broker: broker)
                            ToolApprovalCards(broker: broker)
                        }
                        if let notice = chat.condensationNotice {
                            InlineNotice(.info, symbol: "text.badge.minus", title: notice)
                        }
                        Color.clear.frame(height: 1).id("conversation.end")
                    }
                    .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                }
            }
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("conversation.end", anchor: .bottom) }
            .onChange(of: chat.messages.count) { proxy.scrollTo("conversation.end", anchor: .bottom) }
            .onChange(of: chat.environment.toolBroker?.pendingApprovals.count) {
                proxy.scrollTo("conversation.end", anchor: .bottom)
            }
        }
    }
}

struct ChatMessageView: View {
    let chat: AIChatModel
    let message: ChatMessage
    var isLatest: Bool
    let actions: ChatMessageActions

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(message.attachmentLabels, id: \.self) { label in
                    AttachmentChip(label) { Image(systemName: "paperclip").font(.system(size: 11)) }
                }
                let text = message.displayText ?? message.text
                if !text.isEmpty {
                    Text(text).font(OR.Font.body).lineSpacing(3).foregroundStyle(OR.Color.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(
                            OR.Color.fill2,
                            in: UnevenRoundedRectangle(
                                topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 5, topTrailingRadius: 14,
                                style: .continuous))
                }
            }
            .frame(maxWidth: 520, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(message.displayText ?? message.text)")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty && chat.isGenerating {
                    // Marks where the reply will appear. The action bar says “Writing on this Mac…”.
                    Spinner(size: 14, lineWidth: 1.75).frame(height: 20)
                } else {
                    AIMessageText(message: message).equatable()
                        .font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(OR.Color.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.isPartial && !chat.isGenerating {
                    Label("Stopped", systemImage: "stop.circle").labelStyle(TightLabelStyle())
                        .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                }
                // Every finished reply keeps its actions. ⌘K stays bound to the latest one.
                if !message.text.isEmpty, !(isLatest && chat.isGenerating) {
                    HStack(spacing: 4) {
                        responseButton("Copy", "doc.on.doc", emphasized: true) { actions.copy(message) }
                        if let title = actions.pasteTitle(message, isLatest) {
                            responseButton(title, "arrow.down.doc") { actions.paste(message, isLatest) }
                        }
                        responseButton("Save as Note", "note.text.badge.plus") { actions.saveNote(message) }
                        if let branch = actions.branch, !chat.isGenerating {
                            responseButton("Branch", "arrow.triangle.branch") { branch(message) }
                        }
                        if isLatest, !chat.isReadOnly {
                            responseButton("Try Again", "arrow.clockwise") { actions.retry() }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private func responseButton(_ title: String, _ symbol: String, emphasized: Bool = false, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(emphasized ? OR.Color.text : OR.Color.text2)
            .padding(.horizontal, 8).frame(height: 26)
            .background(emphasized ? OR.Color.fill1 : .clear, in: .rect(cornerRadius: OR.Radius.chip, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(HoverButtonStyle(radius: OR.Radius.chip))
    }
}

private struct ChatComposer: View {
    @Bindable var model: LauncherModel
    /// The accent ring marks only real keyboard focus, so ⌘K's field never shares it.
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.ai.draft.isEmpty {
                    Text(model.ai.attachments.isEmpty ? "Ask anything" : "Ask about the attached text")
                        .font(.system(size: 13.5)).foregroundStyle(OR.Color.text3)
                        .padding(.top, 2).allowsHitTesting(false).accessibilityHidden(true)
                }
                AIComposerInput(
                    text: Bindable(model.ai).draft, focusRequest: model.focusRequest, submit: model.submitAI,
                    deleteOnEmpty: {
                        // ⌫ removes the last attachment first, then leaves AI.
                        if let attachment = model.ai.attachments.last {
                            model.ai.removeAttachment(attachment.id)
                        } else {
                            model.leaveAI()
                        }
                        return true
                    }, onFocusChange: { focused = $0 }, sessionIdentity: { model.ai.conversationToken.uuidString })
                    .frame(minHeight: 38, maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: composerHeight)
            }
            HStack(spacing: 6) {
                ForEach(model.ai.attachments) { attachment in
                    AttachmentChip(attachment.summary, onRemove: { model.ai.removeAttachment(attachment.id) }) {
                        Image(systemName: attachment.source.symbol).font(.system(size: 11))
                    }
                }
                if !model.ai.attachments.contains(where: { $0.source == .clipboard }) {
                    addButton("Clipboard", "list.clipboard") { model.attachClipboardToAI() }
                }
                if !model.ai.attachments.contains(where: { $0.source == .selection }) {
                    addButton("Selection", "character.cursor.ibeam") {
                        model.attachSelectionFromPreviousApp(reportErrors: true)
                        model.focusRequest += 1
                    }
                }
                if model.aiHub.settings.screenContextEnabled, !model.ai.attachments.contains(where: { $0.source == .screen }) {
                    addButton("Window", "macwindow") {
                        let pid = model.previousApplication?.processIdentifier
                        Task { await model.aiHub.attachScreen(.focusedWindow(processID: pid), to: model.ai) }
                    }
                }
                Spacer(minLength: 8)
                if model.aiHub.settings.dictationEnabled {
                    DictationButton(dictation: model.aiHub.dictation, chat: model.ai)
                }
                if model.ai.pendingCharacterCount > AIChatModel.inputLimit * 8 / 10 {
                    Text("\(model.ai.pendingCharacterCount.formatted()) / \(AIChatModel.inputLimit.formatted())")
                        .font(OR.Font.caption).monospacedDigit()
                        .foregroundStyle(model.ai.pendingCharacterCount > AIChatModel.inputLimit ? OR.Color.danger : OR.Color.text2)
                }
                sendButton
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 8)
        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
        .fieldRing(focused: focused)
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private var composerHeight: CGFloat {
        let lines = max(1, model.ai.draft.split(separator: "\n", omittingEmptySubsequences: false).count)
        return min(96, max(38, CGFloat(lines) * 20 + 4))
    }

    private var sendButton: some View {
        Button {
            if model.ai.isGenerating { model.ai.cancel() } else { model.ai.send() }
        } label: {
            Image(systemName: model.ai.isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: model.ai.isGenerating ? 11 : 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(OR.Color.accentFill, in: .circle)
                .opacity(model.ai.isGenerating || model.ai.canSend ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!model.ai.isGenerating && !model.ai.canSend)
        .accessibilityLabel(model.ai.isGenerating ? "Stop" : "Send message")
        .accessibilityHint(model.ai.isGenerating ? "Command Period" : "Return")
    }

    private func addButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text2)
            .padding(.leading, 7).padding(.trailing, 9).frame(height: 26)
            .overlay { RoundedRectangle(cornerRadius: OR.Radius.chip, style: .continuous).strokeBorder(OR.Color.separator) }
            .contentShape(.rect)
        }
        .buttonStyle(HoverButtonStyle(radius: OR.Radius.chip))
        .help("Attach the \(title.lowercased()) text to your next message")
    }
}

extension View {
    /// The accent focus ring: a 1 pt accent stroke and a 3 pt soft halo.
    func fieldRing(focused: Bool, radius: CGFloat = OR.Radius.card) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(focused ? OR.Color.accentFill : OR.Color.separator)
        }
        .background {
            if focused {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .stroke(OR.Color.accentSoft, lineWidth: 3).padding(-1.5)
            }
        }
    }
}

// MARK: - Transform

private struct TransformBody: View {
    @Bindable var model: LauncherModel
    @State private var pasteFocused = false

    var body: some View {
        Group {
            if !model.ai.messages.isEmpty {
                WritingTranscript(model: model)
            } else if let app = model.readingSelectionFrom {
                reading(app)
            } else if let attachment = model.ai.attachments.first {
                ready(attachment)
            } else {
                pasteInput
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // ↩ with no field focused does what the action bar's first button says.
            if model.ai.messages.last?.role == .assistant, !model.ai.isGenerating {
                Button("Use Result") { AIView.submitFromField(model) }
                    .keyboardShortcut(.defaultAction).hidden()
            } else if model.ai.messages.isEmpty, !model.ai.attachments.isEmpty {
                // A passage waiting to run has no field of its own.
                Button("Run") { model.submitAI() }
                    .keyboardShortcut(.defaultAction).hidden()
            }
        }
    }

    /// The ⌘C fallback is waiting for the app's copy (work item 2).
    private func reading(_ app: String) -> some View {
        VStack(spacing: 10) {
            Spinner(size: 18, lineWidth: 2)
            Text("Reading the selection in \(app)…").font(OR.Font.body).foregroundStyle(OR.Color.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func ready(_ attachment: AIAttachment) -> some View {
        let count = model.ai.pendingCharacterCount
        let limit = AIChatModel.inputLimit
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(attachment.title).font(OR.Font.headline).foregroundStyle(OR.Color.text)
                Spacer()
                Text("\(attachment.text.count.formatted()) characters").font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
            ScrollView {
                Text(attachment.text).font(OR.Font.reading).lineSpacing(6).foregroundStyle(OR.Color.text)
                    .frame(maxWidth: .infinity, alignment: .topLeading).textSelection(.enabled)
            }
            .padding(14)
            .frame(maxHeight: .infinity)
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
            HStack(spacing: 6) {
                if count > limit {
                    Text(
                        "\(attachment.source == .selection ? "Selection" : "Passage") and instruction total \(count.formatted()) / \(limit.formatted()) characters. Shorten the instruction or choose a shorter passage."
                    )
                    .foregroundStyle(OR.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Press").foregroundStyle(OR.Color.text2)
                    KeyCaps(["↩"], size: .small)
                    Text("to \(model.ai.title.lowercased()).").foregroundStyle(OR.Color.text2)
                    Spacer(minLength: 8)
                    if count > limit * 8 / 10 {
                        Text("\(count.formatted()) / \(limit.formatted())")
                            .font(OR.Font.caption).monospacedDigit().foregroundStyle(OR.Color.text2)
                    }
                }
            }
            .font(OR.Font.callout)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }

    /// Nothing was captured: why, then the clipboard, the selection again, or typing.
    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = model.selectionNotice {
                InlineNotice(
                    .info, symbol: "character.cursor.ibeam", title: notice,
                    detail: "Use the clipboard, or paste or type the text below.")
            } else {
                Text(model.ai.subtitle).font(OR.Font.body).foregroundStyle(OR.Color.text2)
            }
            ZStack(alignment: .topLeading) {
                if model.ai.draft.isEmpty {
                    Text("Paste or type the text to \(model.ai.runTitle.lowercased())")
                        .font(OR.Font.reading).foregroundStyle(OR.Color.text3).padding(.top, 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                AIComposerInput(
                    text: Bindable(model.ai).draft, focusRequest: model.focusRequest, submit: model.submitAI,
                    deleteOnEmpty: {
                        model.leaveAI()
                        return true
                    }, fontSize: 14, onFocusChange: { pasteFocused = $0 },
                    sessionIdentity: { model.ai.conversationToken.uuidString })
            }
            .padding(14)
            .frame(maxHeight: .infinity)
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
            .fieldRing(focused: pasteFocused)
            HStack(spacing: 8) {
                Button("Use Clipboard") { model.attachClipboardToAI() }.buttonStyle(.orSecondary)
                Button("Use Selection") {
                    model.attachSelectionFromPreviousApp(reportErrors: true)
                    model.focusRequest += 1
                }
                .buttonStyle(.orSecondary)
                if !model.accessibilityAllowed {
                    // main #12/#13: without Accessibility, selected text can't come in on its own.
                    Button("Turn On Selected-Text Access…") { model.openSettings(.permissions) }
                        .buttonStyle(.orGhost)
                        .accessibilityIdentifier("ai.selectionAccess")
                }
                Spacer()
                if model.ai.pendingCharacterCount > AIChatModel.inputLimit * 8 / 10 {
                    Text("\(model.ai.pendingCharacterCount.formatted()) / \(AIChatModel.inputLimit.formatted())")
                        .font(OR.Font.caption).monospacedDigit()
                        .foregroundStyle(model.ai.pendingCharacterCount > AIChatModel.inputLimit ? OR.Color.danger : OR.Color.text2)
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
    }
}

/// A writing run, result first (work item 4): the command as a pill where the passage would be,
/// follow-ups as you typed them, and each response as clean text that streams in. The latest one
/// shows its changes inline when its command's highlight setting is on, or ⌘K asks for them.
private struct WritingTranscript: View {
    @Bindable var model: LauncherModel

    var body: some View {
        let messages = model.ai.messages
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        if message.role == .user {
                            if message.id == messages.first?.id {
                                commandPill
                            } else {
                                followUp(message)
                            }
                        } else if message.id == messages.last?.id {
                            latest(message)
                        } else {
                            AIMessageText(message: message).equatable()
                                .font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear.frame(height: 1).id("writing.end")
                }
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            }
            .onChange(of: messages.last?.text) { proxy.scrollTo("writing.end", anchor: .bottom) }
            .onChange(of: messages.count) { proxy.scrollTo("writing.end", anchor: .bottom) }
        }
    }

    /// The run's user turn: the command's icon and name, not the selected text. A click shows
    /// the passage it ran on.
    private var commandPill: some View {
        HStack(spacing: 7) {
            Image(systemName: model.ai.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(OR.Color.text2)
            Text(model.ai.title).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
        }
        .padding(.horizontal, 12).frame(height: 30)
        .background(OR.Color.fill2, in: .capsule)
        .contentShape(.capsule)
        .onTapGesture { if model.ai.attachments.first != nil { model.showsAttachmentPreview.toggle() } }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.ai.attachments.first != nil ? .isButton : [])
        .accessibilityHint(model.ai.attachments.first?.title ?? "")
        .accessibilityAction(named: "Show Original") { model.showsAttachmentPreview = true }
    }

    private func followUp(_ message: ChatMessage) -> some View {
        Text(message.displayText ?? message.text).font(OR.Font.body).lineSpacing(3).foregroundStyle(OR.Color.text)
            .textSelection(.enabled)
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(
                OR.Color.fill2,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 5, topTrailingRadius: 14,
                    style: .continuous))
            .frame(maxWidth: 520, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("You: \(message.displayText ?? message.text)")
    }

    @ViewBuilder private func latest(_ response: ChatMessage) -> some View {
        let ai = model.ai
        if response.text.isEmpty && ai.isGenerating {
            // Marks where the result will appear. The action bar says “Writing on this Mac…”.
            Spinner(size: 14, lineWidth: 1.75).frame(height: 20)
        } else if response.isPartial && !ai.isGenerating {
            // A stopped result is never pasted. Its text stays visible, read-only.
            InlineNotice(
                .warning, symbol: "exclamationmark.triangle", title: "Stopped before finishing.",
                detail: "Nothing will be pasted."
            ) {
                Button("Try Again") { ai.retry() }.buttonStyle(.orSecondary)
            }
            Text(response.text).font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if ai.diffMode == .original, let source = ai.lastSource, !ai.isGenerating {
            Label("Original", systemImage: "doc.plaintext").labelStyle(TightLabelStyle())
                .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
            Text(source).font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } else if ai.action == .proofread, model.aiResultIsUnchanged {
            InlineNotice(
                .success, symbol: "checkmark.circle.fill", title: "No corrections needed.",
                detail: "Your text is already correct, so there's nothing to paste."
            ) {
                Button("Done") { model.leaveAI() }.buttonStyle(.orSecondary)
            }
            Text(response.text).font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text2)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } else if ai.action == .actionItems, ai.command == nil, !ai.repliesToRevision(response) {
            ActionItemsList(message: response)
        } else if ai.diffMode == .changes, let diff = ai.lastDiff, !ai.isGenerating {
            InlineChanges.text(diff)
                .font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text)
                .textRenderer(InlineChanges.Renderer())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(DiffText.spoken(diff))
            if ai.action == .proofread {
                Label(
                    "\(diff.changeCount) correction\(diff.changeCount == 1 ? "" : "s"). Only spelling, grammar and punctuation were changed.",
                    systemImage: "info.circle"
                )
                .labelStyle(TightLabelStyle()).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
        } else if ai.showsDiff {
            // A rewrite is plain text: what's pasted is exactly what's shown.
            Text(response.text).font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            AIMessageText(message: response).equatable()
                .font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The footer of a writing run: the follow-up field (“shorter”, “more formal”). Its ↩ asks for
/// changes, or on an empty field does what the action bar's first button says; ⌘↩ and ⌥↩ reach
/// Copy and Paste Formatted from here too.
private struct FollowUpComposer: View {
    @Bindable var model: LauncherModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(OR.Color.text3)
                .accessibilityHidden(true)
            if model.ai.command == nil {
                LauncherSearchInput(
                    text: Bindable(model.ai).instruction, placeholder: "Ask for changes, such as shorter or more formal",
                    focusRequest: model.focusRequest,
                    submit: { AIView.submitFromField(model) }, move: { _ in }, cancel: model.goBack,
                    paste: { model.performAISecondary() },
                    tertiary: { model.pasteWritingResult(formatted: true) },
                    fontSize: 13.5, accessibilityLabel: "Ask for changes", identifier: "ai.instruction")
                    .frame(maxWidth: .infinity)
            } else {
                // AI Commands take follow-ups in chat.
                Text("Continue in Chat to ask for changes").font(.system(size: 13)).foregroundStyle(OR.Color.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                KeyCaps(["⌘", "J"], size: .small)
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OR.Radius.control, style: .continuous).strokeBorder(OR.Color.separator)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }
}

/// Raycast-style change marks on a result (work item 4): insertions in green on a light green
/// rounded background; deletions aren't shown, only a thin translucent red bar where text went.
enum InlineChanges {
    struct Mark: TextAttribute {
        enum Kind: Hashable { case insertion, deletion }
        var kind: Kind
    }

    /// The result with its marks. Deletions leave a hair space for their bar.
    static func text(_ diff: WordDiff) -> Text {
        var result = Text(verbatim: "")
        for segment in diff.segments {
            let piece: Text
            switch segment {
            case .same(let text):
                piece = Text(verbatim: text)
            case .added(let text):
                piece = Text(verbatim: text).foregroundStyle(OR.Color.success).customAttribute(Mark(kind: .insertion))
            case .removed:
                piece = Text(verbatim: "\u{200A}").customAttribute(Mark(kind: .deletion))
            }
            result = Text("\(result)\(piece)")
        }
        return result
    }

    /// Draws the marks behind the runs that carry them.
    struct Renderer: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            for line in layout {
                for run in line {
                    if let mark = run[Mark.self] {
                        let bounds = run.typographicBounds.rect
                        switch mark.kind {
                        case .insertion:
                            let rect = bounds.insetBy(dx: -2, dy: -1)
                            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(OR.Color.diffAdd))
                        case .deletion:
                            let bar = CGRect(x: bounds.midX - 1, y: bounds.minY, width: 2, height: bounds.height)
                            context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(OR.Color.danger.opacity(0.45)))
                        }
                    }
                    context.draw(run)
                }
            }
        }
    }
}

/// The full text behind a writing command's attachment chip.
private struct AttachmentPopover: View {
    let attachment: AIAttachment
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(attachment.title).font(OR.Font.headline).foregroundStyle(OR.Color.text)
                Spacer(minLength: 0)
                Text("\(attachment.text.count.formatted()) characters").font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
            ScrollView {
                Text(attachment.text).font(OR.Font.reading).lineSpacing(6).foregroundStyle(OR.Color.text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Remove", action: remove).buttonStyle(.orSecondary)
            }
        }
        .padding(14)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached text")
    }
}

enum DiffText {
    /// Deletions are struck through and insertions underlined, so the diff doesn't rely on color alone.
    static func attributed(_ diff: WordDiff) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in diff.segments.enumerated() {
            // A plain thin space keeps a struck word and its replacement from reading as one word.
            if index > 0, case .added = segment, case .removed = diff.segments[index - 1] {
                result.append(AttributedString("\u{2009}"))
            }
            switch segment {
            case .same(let text):
                result.append(AttributedString(text))
            case .removed(let text):
                result.append(chip(text) { run in
                    run.strikethroughStyle = .single
                    run.foregroundColor = OR.Color.danger
                    run.backgroundColor = OR.Color.diffDelete
                })
            case .added(let text):
                result.append(chip(text) { run in
                    run.underlineStyle = .single
                    run.foregroundColor = OR.Color.success
                    run.backgroundColor = OR.Color.diffAdd
                    run.font = Font(NSFont.systemFont(ofSize: 14, weight: .w550))
                })
            }
        }
        return result
    }

    /// A change styled as a chip: six-per-em spaces pad its visible words so the highlight
    /// extends past the glyphs, and the strike or underline stays on the words. Surrounding
    /// spaces and line breaks stay plain, so a change that ends a line doesn't push the next one over.
    private static func chip(_ text: String, style: (inout AttributedString) -> Void) -> AttributedString {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
            let last = text.lastIndex(where: { !$0.isWhitespace })
        else {
            var plain = AttributedString(text)
            style(&plain)
            return plain
        }
        var core = AttributedString(String(text[first...last]))
        style(&core)
        var pad = AttributedString("\u{2006}")
        pad.backgroundColor = core.backgroundColor
        var result = AttributedString(String(text[..<first]))
        result.append(pad)
        result.append(core)
        result.append(pad)
        result.append(AttributedString(String(text[text.index(after: last)...])))
        return result
    }

    /// The diff as VoiceOver reads it, since strikethrough and underline aren't spoken:
    /// “on [monday, changed to Monday].”
    static func spoken(_ diff: WordDiff) -> String {
        func words(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return text.contains(where: \.isNewline) ? "line break" : "space"
        }
        var result = ""
        var index = 0
        while index < diff.segments.count {
            switch diff.segments[index] {
            case .same(let text):
                result += text
            case .removed(let old):
                if index + 1 < diff.segments.count, case .added(let new) = diff.segments[index + 1] {
                    result += " [\(words(old)), changed to \(words(new))] "
                    index += 1
                } else {
                    result += " [deleted: \(words(old))] "
                }
            case .added(let new):
                result += " [inserted: \(words(new))] "
            }
            index += 1
        }
        return result
    }
}

private struct ActionItemsList: View {
    var message: ChatMessage

    var body: some View {
        let items = message.checklistItems
        VStack(alignment: .leading, spacing: 12) {
            Text(items.isEmpty ? "Action items" : "\(items.count) action item\(items.count == 1 ? "" : "s")")
                .font(OR.Font.headline).foregroundStyle(OR.Color.text)
            if items.isEmpty {
                InlineNotice(.info, symbol: "checklist", title: "No action items found.", detail: "Nothing in this text asks someone to do something.")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            if index > 0 { Hairline() }
                            row(item)
                        }
                    }
                    .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous).strokeBorder(OR.Color.separator)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Owner and date chips come only from the structured fields, never from the task text.
    private func row(_ item: AIActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(OR.Color.text2)
            Text(item.task).font(.system(size: 13)).foregroundStyle(OR.Color.text).frame(maxWidth: .infinity, alignment: .leading)
            // Owner and date are data, so both chips are neutral; the accent is kept for focus and tokens.
            if let owner = item.owner {
                HStack(spacing: 4) {
                    Image(systemName: "person").font(.system(size: 10, weight: .medium))
                    Text(owner).lineLimit(1).fixedSize()
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(OR.Color.text2)
                .padding(.horizontal, 7).frame(height: 20)
                .background(OR.Color.fill2, in: .rect(cornerRadius: 6, style: .continuous))
            }
            if let due = item.due {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.system(size: 10, weight: .medium))
                    Text(due).lineLimit(1).fixedSize()
                }
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(OR.Color.text2)
                .padding(.horizontal, 7).frame(height: 20)
                .background(OR.Color.fill2, in: .rect(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(item))
    }

    private func spokenLabel(_ item: AIActionItem) -> String {
        var parts = [item.task]
        if let owner = item.owner { parts.append("Owner: \(owner)") }
        if let due = item.due { parts.append("Due: \(due)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Unavailable

private struct AIUnavailableView: View {
    let model: LauncherModel

    var body: some View {
        let availability = model.ai.availability
        VStack(spacing: 0) {
            KindTile(kind: .ai, size: 40).padding(.bottom, 14)
            Text(availability.headline).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                .foregroundStyle(OR.Color.text)
            Text("OpenRay's AI runs only on this Mac, with Apple's on-device model.\(blockingNote)")
                .font(OR.Font.body).foregroundStyle(OR.Color.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 420).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(availability.requirements.enumerated()), id: \.offset) { index, requirement in
                    if index > 0 { Hairline() }
                    HStack(spacing: 10) {
                        switch requirement.state {
                        case .met:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(OR.Color.success)
                                .accessibilityHidden(true)
                        case .waiting:
                            Spinner(size: 15, lineWidth: 1.75)
                        case .blocked:
                            // The step that's blocking is the one to see, so it never uses the faintest text.
                            Image(systemName: "exclamationmark.circle").foregroundStyle(OR.Color.warning)
                                .accessibilityHidden(true)
                        }
                        Text(requirement.title).font(.system(size: 12.5)).foregroundStyle(OR.Color.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let note = requirement.note {
                            Text(note).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                        }
                    }
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(requirement.state == .met ? "Done" : requirement.state == .waiting ? "In progress" : "Needed")
                }
            }
            .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous).strokeBorder(OR.Color.separator) }
            .frame(maxWidth: 440).padding(.top, 16)
            HStack(spacing: 8) {
                if availability != .notEligible {
                    Button("Open Apple Intelligence Settings") { AppleIntelligenceSettings.open() }
                        .buttonStyle(.or(.primary, large: true))
                }
                Button("Check Again") {
                    model.ai.refreshAvailability()
                    model.ai.open(model.ai.action)
                }
                .buttonStyle(.or(.secondary, large: true))
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 40).padding(.top, 30)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var blockingNote: String {
        switch model.ai.availability {
        case .preparing: " One step is left."
        case .notEligible: " This Mac doesn't support it, but everything else in OpenRay does."
        default: ""
        }
    }
}

enum AppleIntelligenceSettings {
    /// Opens the Apple Intelligence & Siri pane, not the System Settings root.
    static func open() {
        let urls = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.speech",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}

struct AIMessageText: View, Equatable {
    let message: ChatMessage

    var body: some View { Text(Self.attributedText(for: message)) }

    static func attributedText(for message: ChatMessage) -> AttributedString {
        message.role == .assistant
            ? AIMessageFormatting.attributed(message.text) : AttributedString(message.text)
    }
}
