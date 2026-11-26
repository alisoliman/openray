import AppKit
import SwiftUI

/// Sizing for the Notes window: a fixed width, and a height that follows the note between limits.
enum NotesWindowGeometry {
    static let width: CGFloat = 460
    static let minimumHeight: CGFloat = 200
    static let maximumHeight: CGFloat = 640
    /// The header, footer and hairlines around the editor.
    static let chrome: CGFloat = 40 + 30 + 2

    /// The window height for a note whose text is `contentHeight` tall.
    static func height(forContent contentHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let ceiling = max(minimumHeight, min(maximumHeight, screenHeight * 0.75))
        return min(max((contentHeight + chrome).rounded(.up), minimumHeight), ceiling)
    }

    /// `frame` resized to `height`, keeping its top edge, and kept on the visible screen.
    static func frame(_ frame: NSRect, resizedTo height: CGFloat, within visible: NSRect) -> NSRect {
        var result = frame
        result.size.height = height
        result.origin.y = frame.maxY - height
        if result.minY < visible.minY { result.origin.y = visible.minY }
        if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
        return result
    }

    /// Where the window first appears: the upper right of the screen, clear of the menu bar.
    static func initialFrame(height: CGFloat, within visible: NSRect) -> NSRect {
        NSRect(
            x: (visible.maxX - width - 24).rounded(), y: (visible.maxY - height - 24).rounded(), width: width, height: height)
    }
}

/// The floating panel. It stays above other apps' windows and takes the standard editing keys
/// itself, since OpenRay has no visible menu bar to route them.
final class NotesPanel: NSPanel {
    var onKeyCommand: ((NotesKeyCommand) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        if let command = NotesKeyCommand.command(
            characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: event.modifierFlags),
            onKeyCommand?(command) == true
        {
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        // The app has no menu bar, so the Edit menu's shortcuts are handled here.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let selector: Selector? =
            switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
            case ("x", .command): #selector(NSText.cut(_:))
            case ("c", .command): #selector(NSText.copy(_:))
            case ("v", .command): #selector(NSText.paste(_:))
            case ("v", [.command, .shift, .option]): #selector(NSTextView.pasteAsPlainText(_:))
            case ("a", .command): #selector(NSText.selectAll(_:))
            case ("z", .command): Selector(("undo:"))
            case ("z", [.command, .shift]): Selector(("redo:"))
            default: nil
            }
        if let selector { return NSApp.sendAction(selector, to: nil, from: self) }
        return false
    }
}

/// The live Notes window. It's refused in tests and isolated verification mode, so nothing
/// floats over the person's work while OpenRay is checked.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate, NotesWindowPresenting {
    let model: NotesWindowModel
    let guardrail: SideEffectGuard
    /// The appearance preference: nil follows the system.
    var appearance: () -> NSAppearance? = { nil }
    private var panel: NotesPanel?
    private weak var textView: NoteTextView?
    private var contentHeight: CGFloat = 0
    /// Stops following the note's height once the person resizes the window themselves.
    private var followsContent = true
    private var isResizingForContent = false

    init(model: NotesWindowModel, guardrail: SideEffectGuard = .current) {
        self.model = model
        self.guardrail = guardrail
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }
    var isKey: Bool { isVisible && panel?.isKeyWindow == true && NSApp.isActive }

    @discardableResult
    func show() -> Bool {
        guard (try? guardrail.check("showing the Notes window")) != nil else { return false }
        if panel == nil { createPanel() }
        guard let panel else { return false }
        panel.appearance = appearance()
        activate()
        panel.makeKeyAndOrderFront(nil)
        if let textView, model.browser == nil { panel.makeFirstResponder(textView) }
        return true
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// The launcher is a non-activating panel, so the app it opened over is still frontmost.
    private func activate() {
        let current = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != current.processIdentifier,
            current.activate(from: front)
        {
            return
        }
        NSApp.activate()
    }

    private func createPanel() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = NotesWindowGeometry.minimumHeight + 80
        let panel = NotesPanel(
            contentRect: NotesWindowGeometry.initialFrame(height: height, within: visible),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Notes"
        panel.identifier = NSUserInterfaceItemIdentifier("openray.notes")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: NotesWindowGeometry.minimumHeight)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.onKeyCommand = { [weak self] command in self?.handle(command) ?? false }
        let root = NotesWindowView(
            model: model,
            onContentHeight: { [weak self] height in self?.contentHeightChanged(height) },
            onTextView: { [weak self] textView in self?.textView = textView },
            onEscape: { [weak self] in self?.escape() })
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrameAutosaveName("openray.notes")
        self.panel = panel
    }

    // MARK: Keys

    /// A Notes shortcut from anywhere in the window.
    func handle(_ command: NotesKeyCommand) -> Bool {
        switch command {
        case .browse: model.toggleBrowser()
        case .newNote:
            model.closeOverlays()
            model.newNote()
        case .back: model.goBack()
        case .forward: model.goForward()
        case .togglePin: model.togglePin()
        case .openPinned(let digit):
            model.closeOverlays()
            model.openPinned(digit: digit)
        case .close: model.hide()
        case .deleteNote:
            model.closeOverlays()
            model.deleteCurrentNote()
        default:
            // Formatting acts on the editor, and only while it has focus.
            guard model.browser == nil, let textView, panel?.firstResponder === textView else { return false }
            if !textView.perform(command), command == .toggleTask { NSSound.beep() }
        }
        return true
    }

    /// Esc closes the `/` menu or the browser first, then the window.
    func escape() {
        if model.slashMenu != nil {
            model.slashMenu = nil
        } else if model.browser != nil {
            model.browser = nil
            if let textView { panel?.makeFirstResponder(textView) }
        } else {
            model.hide()
        }
    }

    // MARK: Size

    private func contentHeightChanged(_ height: CGFloat) {
        contentHeight = height
        guard followsContent, let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let target = NotesWindowGeometry.height(forContent: height, screenHeight: screen.visibleFrame.height)
        guard abs(panel.frame.height - target) > 1 else { return }
        isResizingForContent = true
        panel.setFrame(
            NotesWindowGeometry.frame(panel.frame, resizedTo: target, within: screen.visibleFrame), display: true,
            animate: false)
        isResizingForContent = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // A height the person chose sticks until the window is closed.
        if !isResizingForContent { followsContent = false }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        model.flush()
    }

    func windowWillClose(_ notification: Notification) {
        followsContent = true
    }
}

// MARK: - Views

/// The window's content: a compact header, the editor, and a footer for status and notices.
struct NotesWindowView: View {
    @Bindable var model: NotesWindowModel
    var onContentHeight: (CGFloat) -> Void
    var onTextView: (NoteTextView) -> Void
    var onEscape: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NotesHeader(model: model)
            Hairline()
            ZStack(alignment: .topLeading) {
                NoteEditorView(model: model, onContentHeight: onContentHeight, onTextView: onTextView, onEscape: onEscape)
                if let menu = model.slashMenu, !menu.matches.isEmpty {
                    NoteSlashMenuView(model: model, menu: menu)
                        .offset(x: max(8, menu.anchor.minX - 6), y: menu.anchor.maxY + 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            NotesFooter(model: model)
        }
        .overlay {
            if model.browser != nil {
                NotesBrowserView(model: model, onClose: onEscape).padding(.top, 40)
            }
        }
        .background {
            ZStack {
                VisualEffectBackground(material: .popover, blending: .behindWindow)
                OR.Color.panelTint
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }
}

private struct NotesHeader: View {
    @Bindable var model: NotesWindowModel

    var body: some View {
        HStack(spacing: 2) {
            // Room for the close button.
            Color.clear.frame(width: 58, height: 1)
            Text(model.displayTitle).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text2)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let digit = model.currentPinDigit {
                Label("⌘\(digit)", systemImage: "pin.fill").labelStyle(TightLabelStyle())
                    .font(OR.Font.caption).foregroundStyle(OR.Color.accent)
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(OR.Color.accentSoft, in: .capsule)
                    .help("Pinned. Press ⌘\(digit) to open it.")
                    .padding(.trailing, 4)
            }
            HeaderButton(symbol: "chevron.left", help: "Back (⌘[)", disabled: !model.history.canGoBack) { model.goBack() }
            HeaderButton(symbol: "chevron.right", help: "Forward (⌘])", disabled: !model.history.canGoForward) {
                model.goForward()
            }
            HeaderButton(symbol: "magnifyingglass", help: "Browse Notes (⌘P)") { model.toggleBrowser() }
            HeaderButton(symbol: "square.and.pencil", help: "New Note (⌘N)") {
                model.closeOverlays()
                model.newNote()
            }
            Menu {
                Button(model.currentNote?.isPinned == true ? "Unpin Note" : "Pin Note", systemImage: "pin") {
                    model.togglePin()
                }
                Menu("Export As", systemImage: "square.and.arrow.up") {
                    ForEach(NoteExportFormat.allCases) { format in
                        Button(format.title) { Task { await model.export(format) } }
                    }
                }
                Divider()
                Button("Recently Deleted", systemImage: "trash.slash") {
                    model.browser = NotesBrowserState(showsDeleted: true, selection: model.deletedNotes.first?.id)
                }
                Divider()
                Button("Delete Note", systemImage: "trash", role: .destructive) { model.deleteCurrentNote() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(OR.Color.text2)
            .frame(width: 28, height: 26)
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.trailing, 8)
        .frame(height: 40)
    }
}

private struct HeaderButton: View {
    var symbol: String
    var help: String
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .frame(width: 26, height: 26).contentShape(.rect)
        }
        .buttonStyle(HoverButtonStyle())
        .foregroundStyle(disabled ? OR.Color.text3 : OR.Color.text2)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct NotesFooter: View {
    let model: NotesWindowModel

    var body: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Image(systemName: symbol(for: notice.tone)).foregroundStyle(color(for: notice.tone))
                    .accessibilityHidden(true)
                Text(notice.text).foregroundStyle(OR.Color.text).lineLimit(1)
                    .task(id: notice.id) {
                        try? await Task.sleep(for: notice.tone == .error ? .seconds(6) : OR.Timing.toast)
                        if model.notice?.id == notice.id { model.notice = nil }
                    }
            } else {
                Text(status).foregroundStyle(OR.Color.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("⌘P Browse").foregroundStyle(OR.Color.text3)
        }
        .font(OR.Font.caption)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .announce(model.notice?.text)
    }

    private var status: String {
        let words = model.wordCount
        let count = "\(words.formatted()) word\(words == 1 ? "" : "s")"
        guard let note = model.currentNote, !model.isDraft else { return "New note · \(count)" }
        let elapsed = Date().timeIntervalSince(note.modifiedAt)
        let when = elapsed < 60 ? "just now" : note.modifiedAt.formatted(.relative(presentation: .named))
        return "\(count) · Edited \(when)"
    }

    private func symbol(for tone: NotesNotice.Tone) -> String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning, .error: "exclamationmark.triangle.fill"
        }
    }

    private func color(for tone: NotesNotice.Tone) -> Color {
        switch tone {
        case .success: OR.Color.success
        case .info: OR.Color.info
        case .warning: OR.Color.warning
        case .error: OR.Color.danger
        }
    }
}

/// The `/` menu, under the slash.
private struct NoteSlashMenuView: View {
    let model: NotesWindowModel
    let menu: NoteSlashMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(menu.matches.prefix(8).enumerated()), id: \.element) { index, command in
                Button {
                    var updated = menu
                    updated.selection = index
                    model.slashMenu = updated
                    model.onPickSlashCommand?(command)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: command.symbol).frame(width: 18).foregroundStyle(OR.Color.text2)
                        Text(command.title).foregroundStyle(OR.Color.text)
                        Spacer(minLength: 12)
                        Text(command.hint).font(OR.Font.monoSmall).foregroundStyle(OR.Color.text3)
                    }
                    .font(OR.Font.body)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(
                        index == menu.selection ? OR.Color.fill2 : .clear,
                        in: .rect(cornerRadius: OR.Radius.chip, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == menu.selection ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: 230)
        .popoverSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insert block")
    }
}

/// ⌘P: search notes or Recently Deleted, ↑/↓ to move, ↩ to open or restore.
private struct NotesBrowserView: View {
    @Bindable var model: NotesWindowModel
    var onClose: () -> Void
    @State private var focusRequest = 0

    var body: some View {
        let browser = model.browser ?? NotesBrowserState()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(OR.Color.text3).accessibilityHidden(true)
                LauncherSearchInput(
                    text: Binding(get: { model.browser?.query ?? "" }, set: { model.setBrowserQuery($0) }),
                    placeholder: browser.showsDeleted ? "Search Recently Deleted" : "Search notes",
                    focusRequest: focusRequest,
                    submit: { model.openBrowserSelection() },
                    move: { model.moveBrowserSelection(by: $0) },
                    cancel: onClose,
                    paste: { model.openBrowserSelection() },
                    fontSize: 14, accessibilityLabel: "Search notes", identifier: "notes.browser.search")
                    .frame(height: 30)
                SegmentedPicker(
                    options: [(false, "Notes"), (true, "Deleted")],
                    selection: Binding(get: { browser.showsDeleted }, set: { model.setBrowserShowsDeleted($0) }),
                    accessibilityLabel: "Show")
                    .fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.browserResults) { note in
                            NotesBrowserRow(
                                note: note, selected: note.id == browser.selection, isDeleted: browser.showsDeleted,
                                now: model.now()
                            ) {
                                model.browser?.selection = note.id
                                model.openBrowserSelection()
                            }
                            .id(note.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: browser.selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
            .overlay {
                if model.browserResults.isEmpty {
                    Text(emptyText(browser)).font(OR.Font.body).foregroundStyle(OR.Color.text2)
                        .multilineTextAlignment(.center).padding(24)
                }
            }
            if browser.showsDeleted {
                Hairline()
                HStack(spacing: 8) {
                    if model.confirmsEmptyingDeleted {
                        Text("Delete \(model.deletedNotes.count) notes for good?").foregroundStyle(OR.Color.text)
                        Spacer()
                        Button("Cancel") { model.confirmsEmptyingDeleted = false }.buttonStyle(.orGhost)
                        Button("Empty") { model.emptyRecentlyDeleted() }.buttonStyle(.orDestructive)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Text("Notes stay here for 60 days.").foregroundStyle(OR.Color.text3)
                        Spacer()
                        if let id = browser.selection {
                            Button("Delete Now") { model.deletePermanently(id) }.buttonStyle(.orGhost)
                        }
                        Button("Empty…") { model.confirmsEmptyingDeleted = true }.buttonStyle(.orSecondary)
                            .disabled(model.deletedNotes.isEmpty)
                    }
                }
                .font(OR.Font.caption)
                .padding(.horizontal, 12).frame(height: 36)
            }
        }
        .background {
            ZStack {
                VisualEffectBackground(material: .popover, blending: .behindWindow)
                OR.Color.panelTint
            }
        }
        .onAppear { focusRequest += 1 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(browser.showsDeleted ? "Recently Deleted" : "Browse Notes")
    }

    private func emptyText(_ browser: NotesBrowserState) -> String {
        if !browser.query.trimmingCharacters(in: .whitespaces).isEmpty { return "No notes match “\(browser.query)”." }
        return browser.showsDeleted ? "Recently Deleted is empty." : "No notes yet. Press ⌘N to write one."
    }
}

private struct NotesBrowserRow: View {
    let note: QuickNote
    var selected: Bool
    var isDeleted: Bool
    var now: Date
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "Untitled Note" : note.title).font(OR.Font.rowTitle)
                        .foregroundStyle(OR.Color.text).lineLimit(1)
                    Text(subtitle).font(OR.Font.caption).foregroundStyle(OR.Color.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let digit = note.pinnedIndex.flatMap(NoteCollection.digit(forPinSlot:)) {
                    KeyCaps(["⌘", "\(digit)"])
                }
            }
            .padding(.horizontal, 10).frame(height: 44)
            .background(selected ? OR.Color.fill2 : .clear, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(isDeleted ? "Restores the note" : "Opens the note")
    }

    private var subtitle: String {
        if isDeleted, let expires = note.expiresAt {
            let days = max(0, Int(ceil(expires.timeIntervalSince(now) / 86_400)))
            return "Deleted · removed in \(days) day\(days == 1 ? "" : "s")"
        }
        let body = note.content.split(whereSeparator: \.isNewline).dropFirst().first.map(String.init) ?? ""
        let when = note.modifiedAt.formatted(.relative(presentation: .named))
        return body.isEmpty ? when : "\(when) · \(body.prefix(80))"
    }
}
