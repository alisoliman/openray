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
                if !model.ai.availability.isAvailable {
                    AIUnavailableView(model: model)
                } else if model.ai.action == .chat {
                    ChatBody(model: model)
                } else {
                    TransformBody(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .overlay(alignment: .topTrailing) { attachmentPreview }
        .onAppear { model.ai.refreshAvailability() }
        // The bar says “Writing on this Mac…” while a reply is written, so an earlier
        // problem shouldn't keep covering it. Toasts expire on their own.
        .onChange(of: model.ai.isGenerating) { _, generating in
            if generating, let style = model.feedback?.style, style == .error || style == .warning { model.feedback = nil }
        }
        .background {
            Button("Send") { commandReturn() }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    /// ⌘↩ sends in chat. In writing commands it runs, then replaces or pastes the result;
    /// running again is Try Again (⌘R). Inside ⌘K it runs the entry labelled ⌘↩.
    func commandReturn() {
        guard model.confirmation == nil else { return }
        if model.showActions {
            if let entry = model.actionEntries.first(where: { $0.id == "paste" }) { model.performAction(entry) }
            return
        }
        if model.ai.action != .chat, model.ai.latestResponse != nil, !model.ai.isGenerating {
            model.pasteAIResponse()
        } else if model.ai.canSend {
            model.ai.send()
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            ScopeToken(
                kind: .ai, symbol: model.ai.action.kindSymbol, title: model.ai.action.title,
                onRemove: { model.leaveAI() })
            if model.ai.action != .chat, model.ai.availability.isAvailable, let attachment = model.ai.attachments.first {
                LauncherSearchInput(
                    text: Bindable(model.ai).instruction, placeholder: "Add an instruction (optional)",
                    focusRequest: model.focusRequest,
                    submit: { runOrCopy() }, move: { _ in }, cancel: model.goBack, paste: model.pasteSelected,
                    deleteOnEmpty: {
                        model.leaveAI()
                        return true
                    }, fontSize: 15, accessibilityLabel: "Instruction", identifier: "ai.instruction")
                    .frame(maxWidth: .infinity)
                AttachmentChip(attachment.summary, onRemove: { model.ai.removeAttachment(attachment.id) }) {
                    attachmentIcon(attachment)
                }
                // The chip opens the full text; its xmark still takes its own clicks.
                .contentShape(.rect)
                .onTapGesture { model.showsAttachmentPreview.toggle() }
                .help(attachment.text.prefix(400) + (attachment.text.count > 400 ? "…" : ""))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(attachment.summary)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.showsAttachmentPreview = true }
                .accessibilityAction(named: "Show Attached Text") { model.showsAttachmentPreview = true }
                .accessibilityAction(named: "Remove Attachment") { model.ai.removeAttachment(attachment.id) }
            } else {
                Spacer(minLength: 0)
                if model.ai.availability.isAvailable {
                    HStack(spacing: 6) {
                        Circle().fill(OR.Color.success).frame(width: 6, height: 6)
                        Text("On this Mac")
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text2)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(OR.Color.fill1, in: .capsule)
                    .help("Apple's on-device model. Nothing is sent to a server.")
                    if model.ai.action == .chat {
                        Button {
                            model.ai.newConversation()
                            model.focusRequest += 1
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

    @ViewBuilder private func attachmentIcon(_ attachment: AIAttachment) -> some View {
        if attachment.source == .selection, let url = model.previousApplication?.bundleURL {
            WorkspaceIcon(url: url, size: 16)
        } else {
            Image(systemName: attachment.source.symbol).font(.system(size: 12))
        }
    }

    private func runOrCopy() {
        if model.ai.latestResponse != nil, !model.ai.isGenerating, model.ai.action != .chat {
            if let text = model.ai.latestResponse?.text { model.copy(text) }
        } else {
            model.ai.send()
        }
    }

    // MARK: Bar

    @ViewBuilder private var bar: some View {
        let feedback: Feedback? =
            model.feedback ?? model.ai.errorMessage.map { .error($0) }
            ?? (model.ai.isGenerating ? .working(model.ai.isCancelling ? "Stopping…" : "Writing on this Mac…") : nil)
        ActionBar(
            feedback: feedback, confirmation: model.confirmation,
            context: { context },
            actions: { actions },
            onCancelConfirmation: { model.confirmation = nil },
            onConfirm: { if let confirmation = model.confirmation { model.confirm(confirmation) } })
    }

    @ViewBuilder private var context: some View {
        if !model.ai.availability.isAvailable {
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
        if !model.ai.availability.isAvailable {
            ActionBarButton(title: "Back", keys: ["esc"], style: .ghost) { model.goBack() }
        } else if model.ai.isGenerating {
            ActionBarButton(title: "Stop", keys: ["⌘", "."]) { model.ai.cancel() }
                .disabled(model.ai.isCancelling)
        } else if model.ai.action == .chat {
            ActionBarButton(title: "Send", keys: ["⌘", "↩"]) { model.ai.send() }
                .disabled(!model.ai.canSend)
                .accessibilityIdentifier("ai.send")
            ActionBarDivider()
            ActionBarButton(title: "Actions", keys: ["⌘", "K"], style: .ghost, isOn: model.showActions) {
                model.showActions.toggle()
            }
        } else if model.ai.latestResponse != nil {
            ActionBarButton(title: "Copy", keys: ["↩"]) {
                if let text = model.ai.latestResponse?.text { model.copy(text) }
            }
            if !model.aiResultIsUnchanged {
                ActionBarButton(
                    title: model.aiPasteTitle, keys: ["⌘", "↩"], style: model.aiReplacesSource ? .accent : .ghost
                ) { model.pasteAIResponse() }
            }
            ActionBarDivider()
            ActionBarButton(title: "Actions", keys: ["⌘", "K"], style: .ghost, isOn: model.showActions) {
                model.showActions.toggle()
            }
        } else {
            ActionBarButton(
                title: model.ai.action.runTitle, keys: model.ai.attachments.isEmpty ? ["⌘", "↩"] : ["↩"], style: .accent
            ) { model.ai.send() }
            .disabled(!model.ai.canSend)
        }
    }
}

// MARK: - Chat

private struct ChatBody: View {
    @Bindable var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.ai.messages.isEmpty {
                        emptyChat
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(model.ai.messages) { message in
                                ChatMessageView(model: model, message: message, isLatest: message.id == model.ai.messages.last?.id)
                            }
                            Color.clear.frame(height: 1).id("conversation.end")
                        }
                        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
                    }
                }
                .onChange(of: model.ai.messages.last?.text) { proxy.scrollTo("conversation.end", anchor: .bottom) }
                .onChange(of: model.ai.messages.count) { proxy.scrollTo("conversation.end", anchor: .bottom) }
            }
            ChatComposer(model: model)
        }
    }

    private var emptyChat: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                kind: .ai, title: "Ask anything",
                detail: "Brainstorm, draft or work through a question. Apple's on-device model answers here, and nothing is saved unless you ask."
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

private struct ChatMessageView: View {
    let model: LauncherModel
    let message: ChatMessage
    var isLatest: Bool

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
                if message.text.isEmpty && model.ai.isGenerating {
                    // Marks where the reply will appear. The action bar says “Writing on this Mac…”.
                    Spinner(size: 14, lineWidth: 1.75).frame(height: 20)
                } else {
                    AIMessageText(message: message).equatable()
                        .font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(OR.Color.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.isPartial && !model.ai.isGenerating {
                    Label("Stopped", systemImage: "stop.circle").labelStyle(TightLabelStyle())
                        .font(OR.Font.caption).foregroundStyle(OR.Color.text2)
                }
                // Every finished reply keeps its actions. ⌘K and ⌘↩ stay bound to the latest one.
                if !message.text.isEmpty, !(isLatest && model.ai.isGenerating) {
                    HStack(spacing: 4) {
                        responseButton("Copy", "doc.on.doc", emphasized: true) { model.copy(message.text) }
                        if isLatest {
                            if !model.aiResultIsUnchanged {
                                responseButton(model.aiPasteTitle, "arrow.down.doc") { model.pasteAIResponse() }
                            }
                        } else {
                            responseButton(pasteTitle, "arrow.down.doc") { model.paste(message.text) }
                        }
                        responseButton("Save as Note", "note.text.badge.plus") { model.saveResponseAsNote(message) }
                        if isLatest {
                            responseButton("Try Again", "arrow.clockwise") { model.ai.retry() }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// Earlier replies paste as they are; nothing about them replaces a selection.
    private var pasteTitle: String {
        model.canPasteDirectly || !model.clipboard.usesGeneralPasteboard
            ? "Paste to \(model.targetAppName)" : "Copy · ⌘V in \(model.targetAppName)"
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
                    text: Bindable(model.ai).draft, focusRequest: model.focusRequest, submit: model.ai.send,
                    deleteOnEmpty: {
                        // ⌫ removes the last attachment first, then leaves AI.
                        if let attachment = model.ai.attachments.last {
                            model.ai.removeAttachment(attachment.id)
                        } else {
                            model.leaveAI()
                        }
                        return true
                    }, onFocusChange: { focused = $0 })
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
                Spacer(minLength: 8)
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
        .accessibilityHint(model.ai.isGenerating ? "Command Period" : "Command Return")
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
        // Only a reply that ends the conversation counts, so a failed re-run never shows the old diff.
        let response = model.ai.messages.last.flatMap { $0.role == .assistant ? $0 : nil }
        Group {
            if let response, let source = model.ai.lastSource {
                result(response: response, source: source)
            } else if let attachment = model.ai.attachments.first {
                ready(attachment)
            } else {
                pasteInput
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if model.ai.latestResponse != nil, !model.ai.isGenerating {
                Button("Copy") {
                    if let text = model.ai.latestResponse?.text { model.copy(text) }
                }
                .keyboardShortcut(.defaultAction).hidden()
            }
        }
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
                    Text("to \(model.ai.action.title.lowercased()).").foregroundStyle(OR.Color.text2)
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

    private var pasteInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.ai.action.subtitle).font(OR.Font.body).foregroundStyle(OR.Color.text2)
            ZStack(alignment: .topLeading) {
                if model.ai.draft.isEmpty {
                    Text("Paste or type the text to \(model.ai.action.runTitle.lowercased())")
                        .font(OR.Font.reading).foregroundStyle(OR.Color.text3).padding(.top, 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                AIComposerInput(
                    text: Bindable(model.ai).draft, focusRequest: model.focusRequest, submit: model.ai.send,
                    deleteOnEmpty: {
                        model.leaveAI()
                        return true
                    }, fontSize: 14, onFocusChange: { pasteFocused = $0 })
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

    @ViewBuilder private func result(response: ChatMessage, source: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if response.isPartial && !model.ai.isGenerating {
                stopped(response)
            } else if model.ai.action.showsDiff {
                if let diff = model.ai.lastDiff, !model.ai.isGenerating {
                    if model.ai.action == .proofread && diff.isUnchanged {
                        unchanged(source)
                    } else {
                        changes(diff, response: response, source: source)
                    }
                } else {
                    // The diff is built once, when the result is final. Until then the text streams in as is.
                    Text(model.ai.isGenerating ? "Working…" : "Result").font(OR.Font.headline).foregroundStyle(OR.Color.text)
                    ScrollView {
                        Text(response.text).font(OR.Font.reading).lineSpacing(9).foregroundStyle(OR.Color.text)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: .infinity)
                }
            } else if model.ai.action == .actionItems {
                ActionItemsList(message: response)
            } else {
                Text("Summary").font(OR.Font.headline).foregroundStyle(OR.Color.text)
                ScrollView {
                    AIMessageText(message: response).font(OR.Font.reading).lineSpacing(8).foregroundStyle(OR.Color.text)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
    }

    /// A stopped writing result is never copied or replaced. Its text stays visible, read-only.
    @ViewBuilder private func stopped(_ response: ChatMessage) -> some View {
        InlineNotice(
            .warning, symbol: "exclamationmark.triangle", title: "Stopped before finishing.",
            detail: "Nothing will be replaced."
        ) {
            Button("Try Again") { model.ai.retry() }.buttonStyle(.orSecondary)
        }
        ScrollView {
            Text(response.text).font(OR.Font.reading).lineSpacing(9).foregroundStyle(OR.Color.text2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func unchanged(_ source: String) -> some View {
        InlineNotice(
            .success, symbol: "checkmark.circle.fill", title: "No corrections needed.",
            detail: "Your text is already correct, so nothing will be replaced."
        ) {
            Button("Done") { model.leaveAI() }.buttonStyle(.orSecondary)
        }
        Text(source).font(OR.Font.reading).lineSpacing(9).foregroundStyle(OR.Color.text2)
            .textSelection(.enabled)
    }

    @ViewBuilder private func changes(_ diff: WordDiff, response: ChatMessage, source: String) -> some View {
        HStack {
            Text(diffTitle(diff)).font(OR.Font.headline).foregroundStyle(OR.Color.text)
            Spacer()
            SegmentedPicker(
                options: [(AIDiffMode.changes, "Changes"), (.result, "Result"), (.original, "Original")],
                selection: Bindable(model.ai).diffMode, accessibilityLabel: "Show")
        }
        ScrollView {
            Group {
                switch model.ai.diffMode {
                case .changes: Text(DiffText.attributed(diff)).accessibilityLabel(DiffText.spoken(diff))
                case .result: Text(response.text)
                case .original: Text(source)
                }
            }
            .font(OR.Font.reading).lineSpacing(9).foregroundStyle(OR.Color.text)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: .infinity)
        if model.ai.action == .proofread {
            Label("Only spelling, grammar and punctuation were changed. Names, tone and line breaks are kept.", systemImage: "info.circle")
                .labelStyle(TightLabelStyle()).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
        }
    }

    private func diffTitle(_ diff: WordDiff) -> String {
        let count = diff.changeCount
        let noun = model.ai.action == .proofread ? "correction" : "change"
        return "\(count) \(noun)\(count == 1 ? "" : "s")"
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
