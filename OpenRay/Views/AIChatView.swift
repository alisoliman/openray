import AppKit
import SwiftUI

struct AIChatView: View {
    @Bindable var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var modeSelection

    var body: some View {
        VStack(spacing: 0) {
            header
            modeBar
            Divider().opacity(0.6)
            if let message = model.message { StatusBanner(message: message) { model.message = nil } }
            if let error = model.ai.errorMessage {
                HStack {
                    StatusBanner(message: error)
                    if model.ai.canRetry {
                        AIKeyboardButton("Retry") { model.ai.retry() }.buttonStyle(.bordered).padding(.trailing, 20)
                    }
                    if model.ai.latestCompletedResponse != nil, !model.ai.isGenerating {
                        AIKeyboardButton("Use Last Result") { model.continueAIFromResult() }
                            .buttonStyle(.bordered).padding(.trailing, 20)
                    }
                }
            }
            if model.hasNewSelectedText, !model.ai.isGenerating, !model.ai.messages.isEmpty || !model.ai.draft.isEmpty {
                HStack {
                    Label(
                        "New selection from \(model.selectedTextContext?.sourceName ?? "your app")",
                        systemImage: "selection.pin.in.out")
                    Spacer()
                    AIKeyboardButton("Use as new passage") { model.useCapturedSelection(send: true) }
                }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
            }
            if !model.ai.availability.isAvailable {
                unavailable
            } else {
                conversation
            }
            composer
            Divider().opacity(0.6)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").foregroundStyle(.green)
                Text("On-device · Private by default")
                Spacer()
                Text("⌘↩ New line · Esc Hide").accessibilityHidden(true)
                Divider().frame(height: 14).padding(.horizontal, 6)
                AIKeyboardButton {
                    model.showActions.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Text("Actions")
                        Keycap(text: "⌘ K")
                    }
                }.buttonStyle(RayControlStyle()).keyboardShortcut("k")
                    .accessibilityIdentifier("ai.actions")
                    .background {
                        NativeActionsMenu(
                            isPresented: $model.showActions, title: model.ai.action.title,
                            entries: actionEntries, didClose: { model.focusRequest += 1 }
                        )
                        .accessibilityHidden(true)
                    }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 38)
        }
        .onAppear { model.ai.refreshAvailability() }

    }

    private var header: some View {
        HStack(spacing: 12) {
            AIKeyboardButton(action: model.goBack) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28).background(.primary.opacity(0.06), in: .rect(cornerRadius: 6))
            }.buttonStyle(.plain).accessibilityLabel("Back").help("Back (⌘[) · Esc hides OpenRay")
            HStack(spacing: 8) {
                Text("OpenRay").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                Text("AI Workspace").fontWeight(.semibold)
            }.font(.system(size: 13))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.ai.availability.isAvailable ? Color.green : .orange).frame(width: 5, height: 5)
                Text("Apple Intelligence").font(.system(size: 10, weight: .medium))
            }.foregroundStyle(.secondary)
            AIKeyboardButton {
                model.newAIConversation()
            } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 14))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(RayControlStyle()).disabled(model.ai.isGenerating).keyboardShortcut("n")
            .accessibilityLabel("New conversation").help("New conversation in this tool (⌘N)")
        }.padding(.horizontal, 20).frame(height: 58)
    }

    private var modeBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(AIAction.workspaceActions.enumerated()), id: \.element.id) { index, action in
                let selected = model.ai.action == action
                AIKeyboardButton {
                    model.switchAIAction(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.symbol).font(.system(size: 12, weight: .medium)).accessibilityHidden(
                            true)
                        Text(action.shortTitle).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).frame(height: 33)
                    .foregroundStyle(selected ? Color.purple : Color.secondary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.purple.opacity(0.11))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.purple.opacity(0.16)) }
                                .matchedGeometryEffect(id: "ai.mode", in: modeSelection)
                        }
                    }
                }
                .buttonStyle(RayControlStyle()).disabled(model.ai.isGenerating && !selected)
                .accessibilityLabel(action.title).accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("ai.mode.\(action.id)").help("\(action.title) (⌘\(index + 1))")
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: model.ai.action)
    }

    private var unavailable: some View {
        VStack(spacing: 0) {
            EmptyState(symbol: "sparkles", title: model.ai.availability.title, detail: model.ai.availability.detail)
            HStack {
                AIKeyboardButton("Open System Settings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }.buttonStyle(.borderedProminent)
                AIKeyboardButton("Check Again") {
                    model.ai.refreshAvailability()
                    model.ai.open(model.ai.action)
                }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.ai.messages.isEmpty {
                    welcome
                        .id(model.ai.action)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                } else {
                    LazyVStack(alignment: .leading, spacing: 21) {
                        ForEach(model.ai.messages) { message in messageView(message) }
                        Color.clear.frame(height: 1).id("conversation.end")
                    }.padding(22)
                }
            }
            .onChange(of: model.ai.messages.last?.text) { proxy.scrollTo("conversation.end", anchor: .bottom) }
            .onChange(of: model.ai.messages.count) { proxy.scrollTo("conversation.end", anchor: .bottom) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.ai.action)
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(.purple.opacity(0.08)).frame(width: 88, height: 88).blur(radius: 10)
                RoundedRectangle(cornerRadius: 19)
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.16), .indigo.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 62, height: 62)
                    .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(.purple.opacity(0.18)) }
                Image(systemName: model.ai.action.symbol)
                    .font(.system(size: 26, weight: .light)).foregroundStyle(.purple)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }.frame(height: 76).accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(welcomeTitle).font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(model.ai.action.subtitle + ".")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if model.ai.action == .chat {
                HStack(spacing: 8) {
                    suggestion("Draft a reply", "Help me draft a thoughtful reply to this message: ")
                    suggestion("Brainstorm", "Help me brainstorm ideas for ")
                    suggestion("Explain simply", "Explain this in simple terms: ")
                }.padding(.top, 6)
            } else {
                suggestion("Try an example", examplePassage).padding(.top, 6)
                if !model.accessibilityAllowed {
                    AIKeyboardButton("Enable selected-text access in Settings", systemImage: "selection.pin.in.out") {
                        model.openSettings()
                    }
                    .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai.selectionAccess")
                }
            }
        }.padding(.top, 20).padding(.bottom, 16).frame(maxWidth: .infinity)
    }

    private var welcomeTitle: String {
        switch model.ai.action {
        case .chat: "What’s on your mind?"
        case .rewrite: "Find the right words."
        case .summarize: "Less reading. More clarity."
        case .proofread: "Your voice, polished."
        case .shorten: "Make every word count."
        case .actionItems: "Turn notes into next steps."
        }
    }

    private var examplePassage: String {
        switch model.ai.action {
        case .actionItems:
            "We agreed to launch the new homepage on Friday. Sam will finish the copy by Wednesday. I’ll review the final designs tomorrow and share feedback with the team."
        case .proofread:
            "Thanks for you're feedback on the proposal. I’ve made the change we discussed and the updated version are ready for review."
        default:
            "I wanted to reach out to let you know that we’ve finished the first round of designs. It would be really helpful if you could take a look when you have a chance and let us know what you think before we move on to the next stage."
        }
    }

    private func suggestion(_ title: String, _ prompt: String) -> some View {
        AIKeyboardButton {
            model.ai.useText(prompt)
            model.focusRequest += 1
        } label: {
            Text(title).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(.primary.opacity(0.045), in: .rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.06)) }
        }.buttonStyle(RayControlStyle())
    }

    private func messageView(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: message.role == .user ? "person.crop.circle" : "sparkles")
                .foregroundStyle(message.role == .user ? Color.secondary : .purple)
                .font(.system(size: 15)).frame(width: 25, height: 25)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(message.role == .user ? "You" : "OpenRay AI").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if message.isPartial && !model.ai.isGenerating {
                        Text("Stopped").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                if message.text.isEmpty && model.ai.isGenerating {
                    ProgressView("Thinking on your Mac…").controlSize(.small).font(.system(size: 12))
                } else {
                    AIMessageText(message: message).equatable()
                        .font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.role == .assistant && !message.text.isEmpty && !model.ai.isGenerating {
                    HStack(spacing: 16) {
                        if !message.isPartial, message.id == model.ai.messages.last?.id, model.canAcceptAIResponse {
                            AIKeyboardButton(model.aiAcceptTitle, systemImage: "arrow.up.doc") {
                                model.acceptAIResponse()
                            }
                            .accessibilityIdentifier("ai.accept")
                        }
                        AIKeyboardButton("Copy", systemImage: "doc.on.doc") { model.copy(message.text) }
                        AIKeyboardButton("Save as Note", systemImage: "note.text.badge.plus") {
                            model.editor = .note(
                                QuickNote(
                                    title: "AI — " + String((model.ai.messages.first?.text ?? "Response").prefix(50)),
                                    content: message.text))
                        }
                    }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(.primary)
                }
            }
        }
    }

    private var actionEntries: [NativeActionsMenu.Entry] {
        var entries: [NativeActionsMenu.Entry] = []
        if model.ai.isGenerating {
            entries.append(.init(title: "Stop Response", symbol: "stop.fill") { model.ai.cancel() })
        } else {
            if model.canAcceptAIResponse {
                entries.append(.init(title: model.aiAcceptTitle, symbol: "arrow.up.doc") { model.acceptAIResponse() })
            }
            if let response = model.ai.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                entries.append(.init(title: "Copy Last Response", symbol: "doc.on.doc") { model.copy(response.text) })
            }
            entries.append(
                .init(title: "New Conversation", symbol: "square.and.pencil") {
                    model.newAIConversation()
                })
            for action in AIAction.workspaceActions where action != model.ai.action {
                entries.append(
                    .init(title: action.title, symbol: action.symbol) {
                        model.showActions = false
                        model.switchAIAction(action)
                    })
            }
        }
        if !model.ai.isGenerating {
            if model.ai.latestCompletedResponse != nil {
                entries.append(
                    .init(title: "Use Last Result as New Passage", symbol: "arrow.triangle.2.circlepath") {
                        model.continueAIFromResult()
                    })
            }
            entries.append(.init(title: "Use Clipboard as New Passage", symbol: "clipboard", perform: importClipboard))
            entries.append(
                .init(title: "Use Selected Text", symbol: "selection.pin.in.out") { model.useSelectionForAI() })
        }
        entries.append(
            .init(title: "Back to Launcher", symbol: "arrow.left") {
                model.showActions = false
                model.goBack()
            })
        return entries
    }

    private func importClipboard() {
        if let text = model.clipboard.readText() {
            model.importAIText(text)
        } else {
            model.message = "There is no text on the clipboard."
        }
        model.focusRequest += 1
    }

    private var composer: some View {
        return VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                AIComposerInput(
                    text: Binding(get: { model.ai.draft }, set: { model.ai.draft = $0 }),
                    placeholder: model.ai.hasWritingContext
                        ? "Ask for changes, or press Return to use the result…"
                        : (model.ai.action == .chat
                            ? "Ask anything, or paste text to work with…" : "Paste the text you’d like to work with…"),
                    focusRequest: model.focusRequest, submit: model.submitAI,
                    cancel: model.hideLauncher,
                    sessionIdentity: { model.ai.conversationID.uuidString }
                ).padding(6).frame(height: 88)
            }.background(.primary.opacity(0.025), in: .rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.purple.opacity(0.3), .primary.opacity(0.1)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .shadow(color: .purple.opacity(0.035), radius: 12, y: 3)
            HStack(spacing: 13) {
                AIKeyboardButton("Use Clipboard", systemImage: "clipboard", action: importClipboard)
                    .disabled(model.ai.isGenerating).help("Use clipboard text as a new passage")
                AIKeyboardButton("Use Selected Text", systemImage: "selection.pin.in.out") {
                    model.useSelectionForAI()
                    model.focusRequest += 1
                }.disabled(model.ai.isGenerating).help("Use the selection captured when OpenRay opened")
                Spacer()
                Text("\(model.ai.draft.count.formatted()) / \(AIChatModel.inputLimit.formatted())")
                    .font(.system(size: 11)).foregroundStyle(
                        model.ai.draft.count > AIChatModel.inputLimit ? Color.red : .secondary)
                if model.ai.isGenerating {
                    AIKeyboardButton(model.ai.isCancelling ? "Stopping…" : "Stop", systemImage: "stop.fill") {
                        model.ai.cancel()
                    }
                    .disabled(model.ai.isCancelling).buttonStyle(.bordered)
                } else {
                    AIKeyboardButton {
                        model.submitAI()
                    } label: {
                        HStack {
                            Text(
                                model.canAcceptAIResponse
                                    ? model.aiAcceptTitle : (model.ai.hasWritingContext ? "Update" : "Send")
                            )
                            .lineLimit(1)
                            Text("↩").opacity(0.65)
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(!model.ai.canSend && !model.canAcceptAIResponse)
                    .accessibilityLabel(model.canAcceptAIResponse ? model.aiAcceptTitle : "Send message")
                    .accessibilityIdentifier("ai.send")
                }
            }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.primary)
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
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
