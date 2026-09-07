import AppKit
import SwiftUI

struct AIChatView: View {
    @Bindable var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if let message = model.message { StatusBanner(message: message) { model.message = nil } }
            if let error = model.ai.errorMessage { StatusBanner(message: error) }
            if !model.ai.availability.isAvailable {
                unavailable
            } else {
                conversation
                composer
            }
            Divider().opacity(0.6)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").foregroundStyle(.green)
                Text("On-device · Conversation kept in memory only")
                Spacer()
                Text("AI can make mistakes. Review the result.")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 35)
        }
        .onAppear { model.ai.refreshAvailability() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackButton { model.navigate(to: .home) }
            Image(systemName: "sparkles").font(.system(size: 21)).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.ai.action.title).font(.system(size: 15, weight: .semibold))
                Text("Apple Intelligence").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Chat", systemImage: "square.and.pencil") {
                model.ai.newConversation()
                model.focusRequest += 1
            }
            .font(.system(size: 11)).buttonStyle(.borderless).disabled(model.ai.isGenerating).keyboardShortcut("n")
        }.padding(.horizontal, 20).frame(height: 64)
    }

    private var unavailable: some View {
        VStack(spacing: 0) {
            EmptyState(symbol: "sparkles", title: model.ai.availability.title, detail: model.ai.availability.detail)
            HStack {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                }.buttonStyle(.borderedProminent)
                Button("Check Again") {
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
                    VStack(spacing: 10) {
                        EmptyState(
                            symbol: model.ai.action.symbol,
                            title: model.ai.action == .chat
                                ? "A little help. Entirely on your Mac." : model.ai.action.title,
                            detail: model.ai.action == .chat
                                ? "Brainstorm an idea, find the right words, or work through a question. Nothing is sent to a cloud model."
                                : model.ai.action.subtitle + ". Paste a passage below to get started.")
                        if model.ai.action == .chat {
                            HStack(spacing: 8) {
                                suggestion(
                                    "Draft a thoughtful reply", "Help me draft a thoughtful reply to this message: ")
                                suggestion("Brainstorm an idea", "Help me brainstorm ideas for ")
                                suggestion("Explain simply", "Explain this in simple terms: ")
                            }
                        }
                    }.padding(.top, 12)
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
    }

    private func suggestion(_ title: String, _ prompt: String) -> some View {
        Button {
            model.ai.useText(prompt)
            model.focusRequest += 1
        } label: {
            Text(title).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 8)
                .background(.primary.opacity(0.045), in: .rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.06)) }
        }.buttonStyle(.plain)
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
                        Text("Stopped").font(.system(size: 10)).foregroundStyle(.orange)
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
                        Button("Copy", systemImage: "doc.on.doc") { model.copy(message.text) }
                        Button("Save as Note", systemImage: "note.text.badge.plus") {
                            model.editor = .note(
                                QuickNote(
                                    title: "AI — " + String((model.ai.messages.first?.text ?? "Response").prefix(50)),
                                    content: message.text))
                        }
                    }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var composer: some View {
        @Bindable var chat = model.ai
        return VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.ai.draft.isEmpty {
                    Text(
                        model.ai.action == .chat
                            ? "Ask anything, or paste text to work with…" : "Paste the text you’d like to work with…"
                    )
                    .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.top, 10).padding(.leading, 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                AIComposerInput(text: $chat.draft, focusRequest: model.focusRequest, submit: model.ai.send)
                    .padding(6).frame(height: 77)
            }.background(.primary.opacity(0.045), in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.09)) }
            HStack(spacing: 13) {
                Button("Use Clipboard", systemImage: "clipboard") {
                    if let text = model.clipboard.readText() {
                        model.ai.useText(text)
                    } else {
                        model.message = "There is no text on the clipboard."
                    }
                    model.focusRequest += 1
                }
                Button("Use Selected Text", systemImage: "selection.pin.in.out") {
                    model.useSelectionForAI()
                    model.focusRequest += 1
                }
                Spacer()
                Text("\(model.ai.draft.count.formatted()) / \(AIChatModel.inputLimit.formatted())")
                    .font(.system(size: 10)).foregroundStyle(
                        model.ai.draft.count > AIChatModel.inputLimit ? Color.red : .secondary)
                if model.ai.isGenerating {
                    Button(model.ai.isCancelling ? "Stopping…" : "Stop", systemImage: "stop.fill") { model.ai.cancel() }
                        .disabled(model.ai.isCancelling).buttonStyle(.bordered)
                } else {
                    Button {
                        model.ai.send()
                    } label: {
                        HStack {
                            Text("Send")
                            Text("⌘↩").opacity(0.65)
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(!model.ai.canSend)
                    .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send message")
                    .accessibilityIdentifier("ai.send")
                }
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
    }
}

struct AIMessageText: View, Equatable {
    let message: ChatMessage

    var body: some View { Text(Self.attributedText(for: message)) }

    static func attributedText(for message: ChatMessage) -> AttributedString {
        guard message.role == .assistant,
            var text = try? AttributedString(
                markdown: message.text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(message.text) }
        // Responses support emphasis and inline code. Generated link targets are
        // kept inert; Copy and Save as Note retain the original response text.
        text.link = nil
        return text
    }
}
