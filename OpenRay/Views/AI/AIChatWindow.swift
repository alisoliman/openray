import AppKit
import SwiftUI

/// The AI Chat window: saved chats in a sidebar beside the conversation. It can stay on top.
final class AIChatWindowController: AuxiliaryWindowController {
    override func makeRootView() -> AnyView { AnyView(AIChatWindowView(model: model, hub: model.aiHub, controller: self)) }
    override var title: String { "AI Chat" }
    override var initialSize: NSSize { NSSize(width: 880, height: 640) }
    override var minimumSize: NSSize { NSSize(width: 640, height: 440) }
    override var identifier: String { "openray.aichat" }

    func show() {
        showWindow()
        applyLevel()
    }

    func applyLevel() {
        window?.level = model.aiHub.settings.chatWindowOnTop ? .floating : .normal
    }

    override func windowWillClose(_ notification: Notification) {
        super.windowWillClose(notification)
        model.aiHub.saveWindowChat()
    }
}

/// Which chats the sidebar lists.
enum ChatSidebarScope: String, CaseIterable, Identifiable {
    case chats, archive, deleted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chats: "Chats"
        case .archive: "Archive"
        case .deleted: "Recently Deleted"
        }
    }
    var storeScope: ChatStore.Scope {
        switch self {
        case .chats: .recent
        case .archive: .archived
        case .deleted: .recentlyDeleted
        }
    }
}

struct AIChatWindowView: View {
    let model: LauncherModel
    @Bindable var hub: AIHub
    let controller: AIChatWindowController
    @State private var search = ""
    @State private var scope = ChatSidebarScope.chats
    @State private var showsAgents = false
    @State private var notice: String?
    @State private var focusRequest = 0
    @State private var composerFocused = false

    private var chat: AIChatModel { hub.windowChat }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            conversation
        }
        .toolbar { toolbar }
        .background { shortcuts }
        .onAppear {
            chat.refreshAvailability()
            focusRequest += 1
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let chats = hub.chatStore.search(search, in: scope.storeScope)
        let pinned = scope == .chats && search.isEmpty ? hub.chatStore.pinned : []
        return VStack(spacing: 0) {
            List(selection: Binding(get: { chat.chatID }, set: { id in if let id { open(id) } })) {
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, saved in
                            row(saved, number: index + 1)
                        }
                    }
                }
                Section(pinned.isEmpty ? scope.title : "Chats") {
                    ForEach(chats.filter { !pinned.map(\.id).contains($0.id) }) { saved in row(saved, number: nil) }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search Chats")
            .overlay {
                if chats.isEmpty, pinned.isEmpty {
                    Text(search.isEmpty ? emptyTitle : "No chats match “\(search)”")
                        .font(OR.Font.callout).foregroundStyle(OR.Color.text2).multilineTextAlignment(.center).padding()
                }
            }
            Divider()
            HStack {
                Picker("Show", selection: $scope) {
                    ForEach(ChatSidebarScope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).neutralMenus().fixedSize()
                Spacer()
                if scope == .deleted, !hub.chatStore.recentlyDeleted.isEmpty {
                    Button("Empty") { hub.emptyRecentlyDeleted() }.buttonStyle(.orGhost)
                }
            }
            .padding(.horizontal, 10).frame(height: 36)
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .chats: "No saved chats yet.\nAsk something to start one."
        case .archive: "Archived chats appear here."
        case .deleted: "Deleted chats stay here for \(ChatStore.recentlyDeletedDays) days."
        }
    }

    private func row(_ saved: SavedChat, number: Int?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.title).lineLimit(1)
                Text(saved.updatedAt.formatted(.relative(presentation: .named))).font(OR.Font.caption)
                    .foregroundStyle(OR.Color.text2)
            }
            Spacer(minLength: 4)
            if let number { KeyCaps(["⌘", "\(number)"], size: .small) }
        }
        .tag(saved.id)
        .contextMenu {
            if saved.isDeleted {
                Button("Restore") { hub.restoreChat(saved.id) }
                Button("Delete Permanently", role: .destructive) { hub.deletePermanently(saved.id) }
            } else {
                Button(saved.isPinned ? "Unpin" : "Pin") {
                    if saved.isPinned { hub.chatStore.unpin(saved.id) } else { hub.chatStore.pin(saved.id) }
                }
                if saved.isPinned {
                    Button("Move Up") { hub.chatStore.movePin(saved.id, by: -1) }
                    Button("Move Down") { hub.chatStore.movePin(saved.id, by: 1) }
                }
                Button(saved.isArchived ? "Unarchive" : "Archive") {
                    if saved.isArchived { hub.chatStore.unarchive(saved.id) } else { hub.archiveChat(saved.id) }
                }
                Divider()
                Button("Delete", role: .destructive) { hub.deleteChat(saved.id) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func open(_ id: UUID) {
        guard id != chat.chatID else { return }
        if chat.isGenerating {
            notice = "Wait for the reply to finish, or stop it, before opening another chat."
            return
        }
        // A conversation that couldn't be saved stays open, with the reason below.
        guard hub.show(id) else { return }
        notice = nil
        focusRequest += 1
    }

    private func startNewChat() {
        guard hub.newWindowChat() else { return }
        notice = nil
        focusRequest += 1
    }

    // MARK: Conversation

    @ViewBuilder private var conversation: some View {
        VStack(spacing: 0) {
            if !chat.availability.isAvailable {
                InlineNotice(.warning, symbol: "exclamationmark.triangle", title: chat.availability.headline, detail: chat.availability.detail) {
                    Button("Check Again") { chat.refreshAvailability() }.buttonStyle(.orSecondary)
                }
                .padding(14)
            }
            if chat.isReadOnly, let deleted = chat.chatID.flatMap(hub.chatStore.chat(id:)), deleted.isDeleted {
                InlineNotice(
                    .info, symbol: "trash", title: "This chat is in Recently Deleted.",
                    detail: "It's read-only until you restore it."
                ) {
                    Button("Restore") { hub.restoreChat(deleted.id) }.buttonStyle(.orSecondary)
                }
                .padding(14)
            }
            ChatTranscript(chat: chat, actions: actions) {
                EmptyStateView(
                    kind: .ai, title: "Start a chat",
                    detail: "Chats here are saved on this Mac. Type @ to use your notes, clipboard or files, / to pick an agent, or attach a file.")
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ChatSuggestions(chat: chat, agents: hub.agents, extensions: hub.toolExtensions) { focusRequest += 1 }
            composer
            if let message = hub.saveError ?? notice ?? chat.errorMessage ?? hub.chatStore.errorMessage {
                Text(message).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                    .onTapGesture { notice = nil }
            }
        }
        .background(OR.Color.panelSolid)
    }

    private var actions: ChatMessageActions {
        ChatMessageActions(
            copy: { message in
                if model.clipboard.copy(message.text) { notice = "Copied." } else { notice = "Couldn't write to the clipboard." }
            },
            pasteTitle: { _, _ in nil },
            paste: { _, _ in },
            saveNote: { message in
                let note = QuickNote(title: chatTitle(for: message), content: message.text)
                notice = model.store.save(note) ? "Saved as a note." : (model.store.errorMessage ?? "The note couldn't be saved.")
            },
            retry: { chat.retry() },
            branch: chat.chatID == nil || chat.isReadOnly ? nil : { message in hub.branch(from: message.id) })
    }

    private func chatTitle(for message: ChatMessage) -> String {
        let index = chat.messages.firstIndex { $0.id == message.id } ?? chat.messages.endIndex
        let prompt = chat.messages[..<index].last { $0.role == .user }
        let typed = prompt.map { $0.displayText ?? $0.text } ?? ""
        return QuickNote.derivedTitle(from: typed.isEmpty ? "AI response" : typed)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.attachments) { attachment in
                            AttachmentChip(attachment.summary, onRemove: { chat.removeAttachment(attachment.id) }) {
                                Image(systemName: attachment.source.symbol).font(.system(size: 11))
                            }
                        }
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                if chat.draft.isEmpty {
                    Text("Message \((chat.agent ?? .assistant).name)").font(.system(size: 13.5)).foregroundStyle(OR.Color.text3)
                        .padding(.top, 2).allowsHitTesting(false).accessibilityHidden(true)
                }
                AIComposerInput(
                    text: Bindable(chat).draft, focusRequest: focusRequest, submit: send,
                    onFocusChange: { composerFocused = $0 }, sessionIdentity: { chat.conversationToken.uuidString })
                    .frame(minHeight: 38, maxHeight: 140)
            }
            HStack(spacing: 6) {
                attachMenu
                Spacer(minLength: 8)
                if hub.settings.dictationEnabled { DictationButton(dictation: hub.dictation, chat: chat) }
                Button {
                    if chat.isGenerating { chat.cancel() } else { send() }
                } label: {
                    Image(systemName: chat.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: chat.isGenerating ? 11 : 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(OR.Color.accentFill, in: .circle)
                        .opacity(chat.isGenerating || chat.canSend ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!chat.isGenerating && !chat.canSend)
                .accessibilityLabel(chat.isGenerating ? "Stop" : "Send message")
            }
        }
        .disabled(chat.isReadOnly)
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 8)
        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
        .fieldRing(focused: composerFocused)
        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 4)
    }

    private var attachMenu: some View {
        Menu {
            Button("File…") { chooseFiles() }
            let notes = model.store.database.notes.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(12)
            if !notes.isEmpty {
                Menu("Note") {
                    ForEach(Array(notes)) { note in Button(note.title) { hub.attachNote(note, to: chat) } }
                }
            }
            let entries = model.store.database.clipboard.sorted { $0.copiedAt > $1.copiedAt }
                .filter { ($0.plainText ?? $0.recognizedText) != nil }.prefix(12)
            if !entries.isEmpty {
                Menu("Clipboard") {
                    ForEach(Array(entries), id: \.id) { entry in
                        Button(String((entry.plainText ?? entry.recognizedText ?? "").prefix(60))) {
                            hub.attachClipboardEntry(entry, to: chat)
                        }
                    }
                }
            }
            if hub.settings.screenContextEnabled {
                Divider()
                Button("Frontmost Window") {
                    let pid = model.previousApplication?.processIdentifier
                    Task { await hub.attachScreen(.focusedWindow(processID: pid), to: chat) }
                }
                Button("Entire Screen") { Task { await hub.attachScreen(.entireScreen, to: chat) } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperclip").font(.system(size: 11))
                Text("Attach")
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(OR.Color.text2)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .disabled(chat.isGenerating)
    }

    private func chooseFiles() {
        guard !SideEffectGuard.isInert, let window = controller.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Text, code, PDFs and images are read on this Mac."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await hub.attachFiles(urls, to: chat) }
        }
    }

    private func send() {
        notice = nil
        chat.send()
        focusRequest += 1
    }

    // MARK: Toolbar and keys

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsAgents.toggle()
            } label: {
                Label((chat.agent ?? .assistant).name, systemImage: (chat.agent ?? .assistant).symbol)
            }
            .help("Choose an agent (⌘K)")
            .popover(isPresented: $showsAgents, arrowEdge: .bottom) { agentPicker }
            Button {
                hub.updateSettings { $0.chatWindowOnTop.toggle() }
                controller.applyLevel()
            } label: {
                Label("Keep on Top", systemImage: hub.settings.chatWindowOnTop ? "pin.fill" : "pin")
            }
            .help(hub.settings.chatWindowOnTop ? "Stop keeping this window on top" : "Keep this window on top")
            Button {
                startNewChat()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .help("New Chat (⌘N)")
            .disabled(chat.isGenerating)
        }
    }

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(hub.agents) { agent in
                Button {
                    chat.selectAgent(agent)
                    showsAgents = false
                    focusRequest += 1
                } label: {
                    HStack {
                        Image(systemName: agent.symbol).frame(width: 18)
                        Text(agent.name)
                        Spacer()
                        if agent.id == (chat.agent ?? .assistant).id { Image(systemName: "checkmark") }
                    }
                    .padding(.horizontal, 8).frame(height: 28).contentShape(.rect)
                }
                .buttonStyle(HoverButtonStyle(radius: OR.Radius.chip))
            }
            Divider().padding(.vertical, 4)
            Button("New Agent…") {
                showsAgents = false
                hub.requestEditor(.newAgent)
            }
            .buttonStyle(.orGhost)
        }
        .padding(8).frame(width: 240)
    }

    private var shortcuts: some View {
        ZStack {
            Button("New Chat") { startNewChat() }
                .keyboardShortcut("n")
            Button("Agents") { showsAgents.toggle() }.keyboardShortcut("k")
            Button("Stop") { chat.cancel() }.keyboardShortcut(".")
            ForEach(1...9, id: \.self) { number in
                Button("Pinned Chat \(number)") {
                    if let saved = hub.chatStore.pinned(at: number) { open(saved.id) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}
