import AppKit
import SwiftUI

/// Fonts and colors for the Notes editor, from the design tokens.
enum NoteTheme {
    static let bodySize: CGFloat = 14
    static var body: NSFont { .systemFont(ofSize: bodySize) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: 12.5, weight: .regular) }
    static var small: NSFont { .systemFont(ofSize: 12) }

    static func heading(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [22, 18, 15.5, 14, 14, 14]
        return .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: level == 1 ? .w650 : .semibold)
    }

    static var text: NSColor { OR.NS.text }
    static var secondary: NSColor { OR.NS.text2 }
    static var tertiary: NSColor { OR.NS.text3 }
    static var accent: NSColor { OR.NS.accent }
    static var success: NSColor { NSColor(OR.Color.success) }
    static var codeFill: NSColor { OR.NS.fill(light: 0.05, dark: 0.08) }

    static let lineSpacing: CGFloat = 3
    /// The widest and tallest an image preview gets.
    static let maximumImageSize = CGSize(width: 420, height: 260)

    /// Where a ⌘-click on a link goes.
    static let linkKey = NSAttributedString.Key("OpenRayNoteLink")
}

/// The Notes editor: a TextKit 1 text view that styles Markdown as you type, toggles a task
/// when you click its box, and shows each image under its own reference line.
final class NoteTextView: NSTextView {
    /// Pasted or dropped images. Return true when the pasteboard held one and it was inserted.
    var onImagePasteboard: ((NSPasteboard) -> Bool)?
    /// The text's height changed, for the window to size itself.
    var onContentHeight: ((CGFloat) -> Void)?
    /// Resolves an image reference to its file.
    var resolveImage: ((String) -> URL?)?

    private var imageCache: [String: NSImage] = [:]
    private var imageViews: [String: NSImageView] = [:]
    private var imageLines: [(range: NSRange, reference: String)] = []
    private var lastWidth: CGFloat = 0
    private var lastReportedHeight: CGFloat = -1

    // MARK: Editing

    /// Makes an edit the way typing does, so it can be undone, then selects `edit.selection`.
    func apply(_ edit: NoteMarkdown.Edit) {
        let length = (string as NSString).length
        guard NSMaxRange(edit.range) <= length, shouldChangeText(in: edit.range, replacementString: edit.replacement)
        else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        let newLength = (string as NSString).length
        let selection = NSRange(
            location: min(edit.selection.location, newLength),
            length: min(edit.selection.length, max(0, newLength - min(edit.selection.location, newLength))))
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }

    /// Runs a formatting or task command on the selection. False when the command doesn't apply,
    /// such as ⌘↩ on a line that isn't a task.
    @discardableResult
    func perform(_ command: NotesKeyCommand) -> Bool {
        guard let edit = command.edit(in: string, selection: selectedRange()) else { return false }
        apply(edit)
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point) {
            // A click on a task's box checks it, wherever the caret is.
            if let box = NoteMarkdown.taskBox(in: string, at: index), rect(for: box).insetBy(dx: -3, dy: -3).contains(point) {
                if let edit = NoteMarkdown.toggleTask(in: string, at: index, selection: selectedRange()) { apply(edit) }
                return
            }
            // ⌘-click opens a link; a plain click edits it.
            if event.modifierFlags.contains(.command), let destination = textStorage?.attribute(NoteTheme.linkKey, at: index, effectiveRange: nil) as? String,
                let url = URL(string: destination), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            {
                if (try? SideEffectGuard.check("opening a link")) != nil { NSWorkspace.shared.open(url) }
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, (string as NSString).length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return index < (string as NSString).length ? index : nil
    }

    /// A character range's rectangle in this view's coordinates.
    func rect(for range: NSRange) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        if onImagePasteboard?(.general) == true { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if onImagePasteboard?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    // MARK: Styling

    /// Restyles the whole note from its Markdown. Attribute changes only: undo and the text are untouched.
    func restyle() {
        guard let storage = textStorage else { return }
        let string = storage.string
        let ns = string as NSString
        let full = NSRange(location: 0, length: storage.length)
        let base = NSMutableParagraphStyle()
        base.lineSpacing = NoteTheme.lineSpacing
        base.paragraphSpacing = 2
        var images: [(range: NSRange, reference: String)] = []

        storage.beginEditing()
        storage.setAttributes(
            [.font: NoteTheme.body, .foregroundColor: NoteTheme.text, .paragraphStyle: base], range: full)
        for span in NoteMarkdown.spans(in: string) {
            let range = span.range
            guard NSMaxRange(range) <= storage.length, range.length > 0 else { continue }
            switch span.style {
            case .heading(let level):
                let paragraph = ns.paragraphRange(for: range)
                storage.addAttribute(.font, value: NoteTheme.heading(level), range: paragraph)
                let style = NSMutableParagraphStyle()
                style.lineSpacing = NoteTheme.lineSpacing
                style.paragraphSpacingBefore = level == 1 ? 6 : 4
                style.paragraphSpacing = 4
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            case .syntax:
                storage.addAttribute(.foregroundColor, value: NoteTheme.tertiary, range: range)
            case .bold:
                storage.applyFontTraits(.boldFontMask, range: range)
            case .italic:
                storage.applyFontTraits(.italicFontMask, range: range)
            case .strikethrough:
                storage.addAttributes(
                    [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NoteTheme.secondary], range: range)
            case .code:
                storage.addAttributes([.font: NoteTheme.mono, .backgroundColor: NoteTheme.codeFill], range: range)
            case .codeBlock:
                storage.addAttributes(
                    [.font: NoteTheme.mono, .backgroundColor: NoteTheme.codeFill, .foregroundColor: NoteTheme.text], range: range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NoteTheme.accent, range: range)
            case .task(let checked):
                storage.addAttributes(
                    [.font: NoteTheme.mono, .foregroundColor: checked ? NoteTheme.success : NoteTheme.accent,
                     .cursor: NSCursor.pointingHand],
                    range: range)
            case .completedTask:
                storage.addAttributes(
                    [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NoteTheme.tertiary], range: range)
            case .link(let destination):
                storage.addAttributes(
                    [.foregroundColor: NoteTheme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                     NoteTheme.linkKey: destination],
                    range: range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NoteTheme.secondary, range: range)
            case .rule:
                storage.addAttribute(.foregroundColor, value: NoteTheme.tertiary, range: range)
            case .image(let reference):
                storage.addAttributes([.foregroundColor: NoteTheme.tertiary, .font: NoteTheme.small], range: range)
                // Only an image alone on its line gets a preview under it.
                let line = NoteMarkdown.lineRange(in: string, at: range.location)
                guard ns.substring(with: line).trimmingCharacters(in: .whitespaces) == ns.substring(with: range),
                    let size = displaySize(for: reference)
                else { continue }
                let style = NSMutableParagraphStyle()
                style.lineSpacing = NoteTheme.lineSpacing
                style.paragraphSpacing = size.height + 12
                storage.addAttribute(.paragraphStyle, value: style, range: ns.paragraphRange(for: line))
                images.append((line, reference))
            }
        }
        storage.endEditing()
        typingAttributes = [.font: NoteTheme.body, .foregroundColor: NoteTheme.text, .paragraphStyle: base]
        imageLines = images
        layoutImages()
    }

    // MARK: Images

    private func image(for reference: String) -> NSImage? {
        if let cached = imageCache[reference] { return cached }
        guard let url = resolveImage?(reference), let image = NSImage(contentsOf: url) else { return nil }
        imageCache[reference] = image
        return image
    }

    private func displaySize(for reference: String) -> CGSize? {
        guard let image = image(for: reference), image.size.width > 0, image.size.height > 0 else { return nil }
        let available = max(80, bounds.width - textContainerInset.width * 2 - 12)
        let maxWidth = min(NoteTheme.maximumImageSize.width, available)
        let scale = min(1, maxWidth / image.size.width, NoteTheme.maximumImageSize.height / image.size.height)
        return CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    }

    /// Places a preview under each image line, in the gap its paragraph spacing leaves.
    private func layoutImages() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        var keep = Set<String>()
        var bottom: CGFloat = 0
        for line in imageLines {
            guard let image = image(for: line.reference), let size = displaySize(for: line.reference) else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let origin = NSPoint(
                x: textContainerOrigin.x + textContainer.lineFragmentPadding, y: textContainerOrigin.y + used.maxY + 6)
            let key = "\(line.range.location):\(line.reference)"
            let view = imageViews[key] ?? {
                let view = NSImageView()
                view.imageScaling = .scaleProportionallyUpOrDown
                view.wantsLayer = true
                view.layer?.cornerRadius = OR.Radius.control
                view.layer?.masksToBounds = true
                view.setAccessibilityLabel("Image")
                addSubview(view)
                imageViews[key] = view
                return view
            }()
            view.image = image
            view.frame = NSRect(origin: origin, size: size)
            bottom = max(bottom, view.frame.maxY)
            keep.insert(key)
        }
        for (key, view) in imageViews where !keep.contains(key) {
            view.removeFromSuperview()
            imageViews[key] = nil
        }
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(used.maxY + textContainerInset.height * 2, bottom + textContainerInset.height)
        if abs(height - lastReportedHeight) > 0.5 {
            lastReportedHeight = height
            onContentHeight?(height)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Previews scale with the width, so a resize restyles notes that have any.
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            if !imageLines.isEmpty { restyle() } else { layoutImages() }
        }
    }

    /// Clears cached previews, for when another note opens.
    func resetImages() {
        imageCache = [:]
        for view in imageViews.values { view.removeFromSuperview() }
        imageViews = [:]
        imageLines = []
        lastReportedHeight = -1
    }
}

/// The Notes window's editor, bound to the window model.
struct NoteEditorView: NSViewRepresentable {
    let model: NotesWindowModel
    var onContentHeight: (CGFloat) -> Void
    /// Hands the text view to the window, which routes formatting shortcuts to it.
    var onTextView: (NoteTextView) -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = NoteTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.insertionPointColor = OR.NS.accentFill
        textView.textContainerInset = NSSize(width: 18, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.setAccessibilityLabel("Note")
        textView.setAccessibilityIdentifier("notes.editor")
        textView.delegate = context.coordinator
        textView.resolveImage = { [assets = model.assets] in assets.url(for: $0) }
        textView.onContentHeight = { [weak coordinator = context.coordinator] height in
            coordinator?.parent.onContentHeight(height)
        }
        model.onPickSlashCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.pickSlashCommand(command)
        }
        textView.onImagePasteboard = { [weak coordinator = context.coordinator] pasteboard in
            coordinator?.insertImage(from: pasteboard) ?? false
        }
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        context.coordinator.load()
        onTextView(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.revision != model.textRevision { context.coordinator.load() }
        // The slash menu's highlighted row can change from the overlay's hover.
        _ = model.slashMenu
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditorView
        weak var textView: NoteTextView?
        weak var scrollView: NSScrollView?
        var revision = -1
        private var isLoading = false
        /// A slash the person closed the menu for, so it doesn't reopen until they type another.
        private var dismissedSlash: Int?

        init(parent: NoteEditorView) { self.parent = parent }

        private var model: NotesWindowModel { parent.model }

        /// Shows the model's text: another note opened.
        func load() {
            guard let textView else { return }
            isLoading = true
            defer { isLoading = false }
            revision = model.textRevision
            textView.resetImages()
            textView.string = model.text
            textView.undoManager?.removeAllActions()
            textView.restyle()
            let end = (model.text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            dismissedSlash = nil
            model.slashMenu = nil
            textView.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView else { return }
            textView.restyle()
            model.edit(textView.string)
            updateSlashMenu()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            updateSlashMenu()
        }

        // MARK: Slash menu

        private func updateSlashMenu() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0, let trigger = NoteSlashCommand.trigger(in: textView.string, caret: selection.location),
                trigger.slash != dismissedSlash, !NoteMarkdown.isInsideCodeBlock(textView.string, at: trigger.slash),
                !NoteSlashCommand.matching(trigger.query).isEmpty
            else {
                if model.slashMenu != nil { model.slashMenu = nil }
                if let dismissedSlash, NoteSlashCommand.trigger(in: textView.string, caret: selection.location)?.slash != dismissedSlash {
                    self.dismissedSlash = nil
                }
                return
            }
            var menu = NoteSlashMenu(slash: trigger.slash, query: trigger.query)
            if let current = model.slashMenu, current.slash == trigger.slash, current.query == trigger.query {
                menu.selection = current.selection
            }
            menu.anchor = anchor(forCharacterAt: trigger.slash)
            if model.slashMenu != menu { model.slashMenu = menu }
        }

        /// The slash's rectangle in the scroll view, with the origin at the top left.
        private func anchor(forCharacterAt location: Int) -> CGRect {
            guard let textView, let scrollView else { return .zero }
            var rect = textView.convert(textView.rect(for: NSRange(location: location, length: 1)), to: scrollView)
            if !scrollView.isFlipped { rect.origin.y = scrollView.bounds.height - rect.maxY }
            return rect
        }

        func pickSlashCommand(_ command: NoteSlashCommand) {
            guard let textView, let menu = model.slashMenu else { return }
            let caret = textView.selectedRange().location
            model.slashMenu = nil
            if command == .image {
                // Remove what was typed, then insert the chosen image there.
                let typed = NSRange(location: menu.slash, length: max(0, caret - menu.slash))
                textView.apply(NoteMarkdown.Edit(range: typed, replacement: "", selection: NSRange(location: menu.slash, length: 0)))
                Task { @MainActor [weak self] in
                    guard let self, let reference = await self.model.pickImage(), let textView = self.textView else { return }
                    textView.apply(NoteMarkdown.insertImage(reference, in: textView.string, selection: textView.selectedRange()))
                }
                return
            }
            if let edit = command.edit(in: textView.string, slash: menu.slash, caret: caret) { textView.apply(edit) }
        }

        func insertImage(from pasteboard: NSPasteboard) -> Bool {
            guard let textView else { return false }
            // Text wins when there's text: copying from a web page often carries an image too.
            let types = pasteboard.types ?? []
            let hasFile = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            if types.contains(.string), !hasFile { return false }
            guard let image = NoteAssetStore.imageData(from: pasteboard) else { return false }
            guard let reference = model.storeImage(image.data, fileExtension: image.fileExtension) else { return true }
            textView.apply(NoteMarkdown.insertImage(reference, in: textView.string, selection: textView.selectedRange()))
            return true
        }

        // MARK: Keys

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if var menu = model.slashMenu {
                let matches = menu.matches
                switch selector {
                case #selector(NSResponder.moveDown(_:)):
                    menu.selection = min(menu.selection + 1, matches.count - 1)
                    model.slashMenu = menu
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    menu.selection = max(menu.selection - 1, 0)
                    model.slashMenu = menu
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if matches.indices.contains(menu.selection) { pickSlashCommand(matches[menu.selection]) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    dismissedSlash = menu.slash
                    model.slashMenu = nil
                    return true
                default:
                    break
                }
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let selection = textView.selectedRange()
                guard selection.length == 0, let edit = NoteMarkdown.newline(in: textView.string, at: selection.location),
                    let noteView = textView as? NoteTextView
                else { return false }
                noteView.apply(edit)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
