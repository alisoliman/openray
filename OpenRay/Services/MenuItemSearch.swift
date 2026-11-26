import AppKit
@preconcurrency import ApplicationServices

// MARK: - Tree source

/// A node in an app's menu tree: an Accessibility element, or a token in tests.
struct MenuNodeRef: Hashable, @unchecked Sendable {
    let token: Int
    let element: AXUIElement?

    init(element: AXUIElement) {
        self.element = element
        token = Int(bitPattern: CFHash(element))
    }

    init(token: Int) {
        self.token = token
        element = nil
    }

    static func == (lhs: MenuNodeRef, rhs: MenuNodeRef) -> Bool {
        guard lhs.token == rhs.token else { return false }
        switch (lhs.element, rhs.element) {
        case (nil, nil): return true
        case let (left?, right?): return CFEqual(left, right)
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(token) }
}

/// One node's own attributes. Children are read separately, only when needed.
struct MenuNodeInfo: Equatable, Sendable {
    /// AXMenuBar, AXMenuBarItem, AXMenu or AXMenuItem.
    var role: String?
    var title: String?
    var isEnabled: Bool = true
    /// kAXMenuItemCmdCharAttribute and friends: the item's keyboard shortcut.
    var commandCharacter: String?
    var commandModifiers: Int?
    var commandGlyph: Int?
    var commandVirtualKey: Int?
}

/// Reads and presses an app's menus. Called on `MenuBarReader`'s serial queue,
/// never on the main actor. `AXMenuTreeSource` is the real one; tests use fakes.
protocol MenuTreeSource: Sendable {
    var isTrusted: Bool { get }
    /// Nil without Accessibility access or when the app has no menu bar.
    func menuBar(of pid: pid_t) -> MenuNodeRef?
    func info(of node: MenuNodeRef) -> MenuNodeInfo
    func children(of node: MenuNodeRef) -> [MenuNodeRef]
    func press(_ node: MenuNodeRef) throws
}

/// A menu item you can run, flattened out of its menus.
struct MenuBarItem: Identifiable, Sendable {
    /// The menus that lead to the item, e.g. ["File", "Export"].
    let path: [String]
    let title: String
    /// Sibling positions from the menu bar down, so two items with the same
    /// label stay separate rows.
    let indexPath: [Int]
    /// Keycaps in menu order, e.g. ["⇧", "⌘", "E"].
    let shortcut: [String]?
    let isEnabled: Bool
    let node: MenuNodeRef

    var id: String { indexPath.map(String.init).joined(separator: ".") }
    /// "File › Export › PDF".
    var pathText: String { (path + [title]).joined(separator: " › ") }
    /// The menus alone, for a subtitle: "File › Export".
    var menuText: String { path.joined(separator: " › ") }
}

/// The items read from one app's menu bar.
struct MenuSnapshot: Sendable {
    var items: [MenuBarItem]
    /// False when a limit stopped the read early.
    var isComplete: Bool
}

// MARK: - Collection

enum MenuItemCollector {
    struct Limits: Sendable {
        var maxDepth = 8
        var maxItems = 4_000
        /// Nodes whose attributes are read; bounds the Accessibility round trips.
        var maxVisitedNodes = 8_000
        var timeBudget: Duration = .seconds(3)
    }

    struct Result: Sendable {
        var items: [MenuBarItem]
        /// A limit stopped the walk before it finished.
        var truncated: Bool
        var cancelled: Bool
    }

    static let menuBarItemRole = "AXMenuBarItem"
    static let menuRole = "AXMenu"
    static let menuItemRole = "AXMenuItem"

    /// Every leaf item under the menu bar, in menu order. Each node's attributes
    /// and children are read at most once, and every read first checks
    /// cancellation and the limits. Separators and empty titles drop out,
    /// submenus become path components, and the Apple menu is skipped unless
    /// asked for: it is the same in every app.
    static func collect(
        from source: any MenuTreeSource, menuBar: MenuNodeRef, includeAppleMenu: Bool = false,
        limits: Limits = Limits(), elapsed: () -> Duration, isCancelled: () -> Bool
    ) -> Result {
        var items: [MenuBarItem] = []
        var visited = 0
        var truncated = false
        var cancelled = false

        func shouldStop() -> Bool {
            if cancelled || truncated { return true }
            if isCancelled() {
                cancelled = true
            } else if visited >= limits.maxVisitedNodes || items.count >= limits.maxItems
                || elapsed() >= limits.timeBudget
            {
                truncated = true
            }
            return cancelled || truncated
        }

        func visit(_ menu: MenuNodeRef, path: [String], indexPath: [Int], depth: Int) {
            guard depth <= limits.maxDepth else {
                truncated = true
                return
            }
            guard !shouldStop() else { return }
            let children = source.children(of: menu)
            for (index, child) in children.enumerated() {
                guard !shouldStop() else { return }
                if depth == 0 && index == 0 && !includeAppleMenu { continue }
                visited += 1
                let info = source.info(of: child)
                switch info.role {
                case menuRole:
                    visit(child, path: path, indexPath: indexPath + [index], depth: depth + 1)
                case menuBarItemRole, menuItemRole:
                    let title = (info.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    // One read finds a submenu; the submenu's own items are read inside it.
                    var submenus: [MenuNodeRef] = []
                    for grandchild in source.children(of: child) {
                        guard !shouldStop() else { return }
                        visited += 1
                        if source.info(of: grandchild).role == menuRole { submenus.append(grandchild) }
                    }
                    if !submenus.isEmpty {
                        for (offset, submenu) in submenus.enumerated() {
                            visit(
                                submenu, path: path + [title], indexPath: indexPath + [index, offset],
                                depth: depth + 1)
                        }
                    } else if info.role == menuItemRole {
                        items.append(
                            MenuBarItem(
                                path: path, title: title, indexPath: indexPath + [index],
                                shortcut: MenuShortcutFormatter.caps(
                                    character: info.commandCharacter, modifiers: info.commandModifiers,
                                    glyph: info.commandGlyph, virtualKey: info.commandVirtualKey),
                                isEnabled: info.isEnabled, node: child))
                    }
                default:
                    continue
                }
            }
        }

        visit(menuBar, path: [], indexPath: [], depth: 0)
        return Result(items: items, truncated: truncated, cancelled: cancelled)
    }
}

/// Turns a menu item's Accessibility shortcut attributes into keycaps.
enum MenuShortcutFormatter {
    // kMenuShiftModifier, kMenuOptionModifier, kMenuControlModifier, kMenuNoCommandModifier.
    static let shift = 1
    static let option = 2
    static let control = 4
    static let noCommand = 8

    /// The glyph wins, then a printable character, then the virtual key.
    static func caps(character: String?, modifiers: Int?, glyph: Int?, virtualKey: Int?) -> [String]? {
        let key = glyph.flatMap(glyphName) ?? character.flatMap(characterName) ?? virtualKey.flatMap(virtualKeyName)
        guard let key else { return nil }
        let flags = modifiers ?? 0
        var caps: [String] = []
        if flags & control != 0 { caps.append("⌃") }
        if flags & option != 0 { caps.append("⌥") }
        if flags & shift != 0 { caps.append("⇧") }
        if flags & noCommand == 0 { caps.append("⌘") }
        caps.append(key)
        return caps
    }

    /// Carbon's menu glyph codes (Menus.h) for keys a character can't show.
    static func glyphName(_ glyph: Int) -> String? {
        switch glyph {
        case 0x02: "⇥"
        case 0x03: "⇤"
        case 0x04: "⌤"
        case 0x09: "Space"
        case 0x0A: "⌦"
        case 0x0B, 0x0C, 0x0D: "↩"
        case 0x10: "⇣"
        case 0x17: "⌫"
        case 0x1B: "⎋"
        case 0x1C: "⌧"
        case 0x62: "⇞"
        case 0x63: "⇪"
        case 0x64: "←"
        case 0x65: "→"
        case 0x66: "↖"
        case 0x67: "Help"
        case 0x68: "↑"
        case 0x69: "↘"
        case 0x6A: "↓"
        case 0x6B: "⇟"
        case 0x6E: "⏻"
        case 0x6F...0x7A: "F\(glyph - 0x6F + 1)"
        case 0x87...0x89: "F\(glyph - 0x87 + 13)"
        case 0x8C: "⏏"
        case 0x8F...0x92: "F\(glyph - 0x8F + 16)"
        default: nil
        }
    }

    /// A shortcut character as a keycap: letters in capitals, function-key
    /// characters by name.
    static func characterName(_ character: String) -> String? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            let trimmed = character.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed.uppercased()
        }
        switch scalar.value {
        case 0x20: return "Space"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71A: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return character.uppercased()
        }
    }

    /// Carbon virtual key codes (kVK_*) for special keys, used when the item has
    /// neither a glyph nor a printable character.
    static func virtualKeyName(_ code: Int) -> String? {
        switch code {
        case 0x24: "↩"
        case 0x30: "⇥"
        case 0x31: "Space"
        case 0x33: "⌫"
        case 0x35: "⎋"
        case 0x4C: "⌤"
        case 0x72: "Help"
        case 0x73: "↖"
        case 0x74: "⇞"
        case 0x75: "⌦"
        case 0x77: "↘"
        case 0x79: "⇟"
        case 0x7B: "←"
        case 0x7C: "→"
        case 0x7D: "↓"
        case 0x7E: "↑"
        case 0x7A: "F1"
        case 0x78: "F2"
        case 0x63: "F3"
        case 0x76: "F4"
        case 0x60: "F5"
        case 0x61: "F6"
        case 0x62: "F7"
        case 0x64: "F8"
        case 0x65: "F9"
        case 0x6D: "F10"
        case 0x67: "F11"
        case 0x6F: "F12"
        case 0x69: "F13"
        case 0x6B: "F14"
        case 0x71: "F15"
        case 0x6A: "F16"
        case 0x40: "F17"
        case 0x4F: "F18"
        case 0x50: "F19"
        case 0x5A: "F20"
        default: nil
        }
    }
}

// MARK: - Reader

/// Walks menus on its own serial queue, so a slow or hung app can't freeze the
/// launcher. Reads stop on cancellation and at the limits.
final class MenuBarReader: Sendable {
    let source: any MenuTreeSource
    private let queue = DispatchQueue(label: "app.openray.menu-bar-reader", qos: .userInitiated)

    init(source: any MenuTreeSource) {
        self.source = source
    }

    func snapshot(
        of pid: pid_t, includeAppleMenu: Bool = false, limits: MenuItemCollector.Limits = .init()
    ) async throws -> MenuSnapshot {
        let flag = BackgroundReadCancellation()
        let source = source
        let queue = queue
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MenuSnapshot, any Error>) in
                queue.async {
                    guard !flag.isSet else { return continuation.resume(throwing: CancellationError()) }
                    guard let root = source.menuBar(of: pid) else {
                        return continuation.resume(
                            throwing: LibraryValidationError("This app doesn't share its menu bar."))
                    }
                    let start = ContinuousClock.now
                    let result = MenuItemCollector.collect(
                        from: source, menuBar: root, includeAppleMenu: includeAppleMenu, limits: limits,
                        elapsed: { ContinuousClock.now - start }, isCancelled: { flag.isSet })
                    if result.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: MenuSnapshot(items: result.items, isComplete: !result.truncated))
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    func press(_ node: MenuNodeRef) async throws {
        let source = source
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try source.press(node)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A flag a cancelled task sets and a background read checks between steps.
final class BackgroundReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: - Search

/// Search Menu Bar Items: the frontmost app's menu items as one searchable list.
/// Read once when the command opens, then filtered locally.
final class MenuItemSearch: Sendable {
    let reader: MenuBarReader

    init(source: any MenuTreeSource = MenuSearchEnvironment.makeSource()) {
        reader = MenuBarReader(source: source)
    }

    var hasPermission: Bool { reader.source.isTrusted }

    func items(for pid: pid_t?, limits: MenuItemCollector.Limits = .init()) async throws -> MenuSnapshot {
        guard reader.source.isTrusted else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to search menu items.")
        }
        guard let pid, pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            throw LibraryValidationError("Open OpenRay from another app to search its menus.")
        }
        return try await reader.snapshot(of: pid, limits: limits)
    }

    /// Ranks by the item's title first, then its whole path, so "pdf" finds
    /// "File › Export › PDF" and "export" finds everything under Export.
    /// Disabled items stay listed but sink below enabled ones with the same score.
    static func filter(_ items: [MenuBarItem], query: String) -> [MenuBarItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let scored = items.enumerated().compactMap { offset, item -> (Int, Int, MenuBarItem)? in
            let title = SearchMatcher.score(trimmed, in: item.title)
            let path = SearchMatcher.score(trimmed, in: item.pathText).map { $0 - 100 }
            guard let score = [title, path].compactMap({ $0 }).max() else { return nil }
            return (score + (item.isEnabled ? 1 : 0), offset, item)
        }
        let ranked = scored.sorted { (lhs: (Int, Int, MenuBarItem), rhs: (Int, Int, MenuBarItem)) -> Bool in
            lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
        }
        return ranked.map { $0.2 }
    }

    /// ↩: runs the item. The caller brings the app forward first.
    func press(_ item: MenuBarItem) async throws {
        guard item.isEnabled else {
            throw LibraryValidationError("“\(item.title)” is unavailable in this app right now.")
        }
        try await reader.press(item.node)
    }
}

enum MenuSearchEnvironment {
    /// Accessibility in a normal launch; an inert source in the test host and in
    /// isolated verification mode.
    static func makeSource(sideEffects: SideEffectGuard = .current) -> any MenuTreeSource {
        let rule = sideEffects.effective
        return rule.isInert ? InertMenuTreeSource(sideEffects: rule) : AXMenuTreeSource(sideEffects: rule)
    }
}

/// Reads nothing and presses nothing. The default in inert launches.
final class InertMenuTreeSource: MenuTreeSource {
    let sideEffects: SideEffectGuard

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    var isTrusted: Bool { false }
    func menuBar(of pid: pid_t) -> MenuNodeRef? { nil }
    func info(of node: MenuNodeRef) -> MenuNodeInfo { MenuNodeInfo() }
    func children(of node: MenuNodeRef) -> [MenuNodeRef] { [] }

    func press(_ node: MenuNodeRef) throws {
        throw SideEffectGuard.Blocked(what: "pressing a menu item", mode: sideEffects.mode)
    }
}

// MARK: - Accessibility

/// The real menus. Each node's attributes come back in one round trip, with a
/// short timeout so a hung app can't stall the reader for long.
final class AXMenuTreeSource: MenuTreeSource {
    private static let timeout: Float = 0.25
    private static let attributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdVirtualKeyAttribute,
    ]

    let sideEffects: SideEffectGuard

    init(sideEffects: SideEffectGuard = .current) {
        self.sideEffects = sideEffects
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func menuBar(of pid: pid_t) -> MenuNodeRef? {
        guard isTrusted else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return MenuNodeRef(element: unsafeDowncast(value, to: AXUIElement.self))
    }

    func info(of node: MenuNodeRef) -> MenuNodeInfo {
        guard let element = node.element else { return MenuNodeInfo() }
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        var values: CFArray?
        guard
            AXUIElementCopyMultipleAttributeValues(
                element, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(), &values) == .success,
            let list = values as? [AnyObject]
        else { return MenuNodeInfo() }
        func value(_ index: Int) -> AnyObject? {
            guard list.indices.contains(index) else { return nil }
            let item = list[index]
            // Missing attributes come back as AXValue errors.
            if CFGetTypeID(item) == AXValueGetTypeID(),
                AXValueGetType(unsafeDowncast(item, to: AXValue.self)) == .axError
            {
                return nil
            }
            return item
        }
        return MenuNodeInfo(
            role: value(0) as? String, title: value(1) as? String, isEnabled: (value(2) as? Bool) ?? true,
            commandCharacter: value(3) as? String, commandModifiers: (value(4) as? NSNumber)?.intValue,
            commandGlyph: (value(5) as? NSNumber)?.intValue, commandVirtualKey: (value(6) as? NSNumber)?.intValue)
    }

    func children(of node: MenuNodeRef) -> [MenuNodeRef] {
        guard let element = node.element else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        return children.map(MenuNodeRef.init(element:))
    }

    func press(_ node: MenuNodeRef) throws {
        try sideEffects.check("pressing a menu item")
        guard let element = node.element,
            AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        else { throw LibraryValidationError("The app didn't run that menu item.") }
    }
}
