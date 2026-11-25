import AppKit

extension LauncherModel {
    var bindableCommands: [LauncherItem] {
        let commands = commandItems
        return CuratedCommand.targetIDs.compactMap { id in commands.first { $0.id == id } }
    }

    var applicationItems: [LauncherItem] {
        applications.applications.map { app in
            LauncherItem(
                id: app.id, title: app.name, subtitle: Self.shortenedPath(app.url.deletingLastPathComponent()),
                symbol: "app", kind: .system, badge: "Application", keywords: app.bundleIdentifier ?? "",
                iconURL: app.url, action: .application(app))
        }
    }

    var fileItems: [LauncherItem] {
        files.results.map { file in
            LauncherItem(
                id: file.id, title: file.name, subtitle: Self.shortenedPath(file.url.deletingLastPathComponent()),
                symbol: file.url.hasDirectoryPath ? "folder" : "doc", kind: .file, badge: Self.fileKind(file.url),
                iconURL: file.url, action: .file(file.url), isLiveResult: true)
        }
    }

    var savedFileItems: [LauncherItem] {
        let ids = store.database.favoriteIDs.union(store.database.usage.map(\.id)).sorted()
        return ids.filter { $0.hasPrefix("file./") }.map { id in
            let url = URL(fileURLWithPath: String(id.dropFirst("file.".count)))
            return LauncherItem(
                id: id, title: url.lastPathComponent, subtitle: Self.shortenedPath(url.deletingLastPathComponent()),
                symbol: "doc", kind: .file, badge: Self.fileKind(url), iconURL: url, action: .file(url))
        }
    }

    var clipboardItems: [LauncherItem] {
        store.database.clipboard.map { entry in
            LauncherItem(
                id: "clipboard.\(entry.id)", title: entry.title,
                subtitle: "\(entry.sourceName) · \(entry.copiedAt.formatted(date: .omitted, time: .shortened))",
                symbol: entry.symbol, kind: .clipboard, badge: entry.kindTitle, keywords: entry.searchableText,
                clipboardImage: entry.image.flatMap { store.imageResource(for: $0) },
                action: .clipboard(entry))
        }
    }

    var quicklinkItems: [LauncherItem] {
        store.database.quicklinks.map { link in
            let argument = link.argument(in: query) ?? ""
            let keywordMatch =
                !query.isEmpty && !link.keyword.isEmpty
                && SearchMatcher.score(query, in: link.name) == nil
                && SearchMatcher.score(query, in: link.keyword) != nil
            let destination = Self.displayURL(link.template.replacingOccurrences(of: "{query}", with: "…"))
            return LauncherItem(
                id: "quicklink.\(link.id)", title: link.name,
                subtitle: argument.isEmpty
                    ? (keywordMatch ? "Keyword match · \(destination)" : destination) : "Search for “\(argument)”",
                // One glyph wherever a quicklink appears: token, action bar, retarget rows.
                symbol: "link", kind: .quicklink, badge: "Quicklink",
                keywords: link.keyword, action: .quicklink(link, argument))
        }
    }

    var snippetItems: [LauncherItem] {
        store.database.snippets.map { snippet in
            let firstLine = snippet.content.split(whereSeparator: \.isNewline).first.map { String($0.prefix(90)) } ?? ""
            return LauncherItem(
                id: "snippet.\(snippet.id)", title: snippet.name, subtitle: firstLine,
                symbol: "curlybraces", kind: .snippet, badge: "Snippet",
                keywords: snippet.keyword + " " + snippet.content, action: .snippet(snippet))
        }
    }

    var noteItems: [LauncherItem] {
        store.database.notes.sorted { $0.modifiedAt > $1.modifiedAt }.map { note in
            let body = note.content.split(whereSeparator: \.isNewline)
                .first { $0.trimmingCharacters(in: .whitespaces) != note.title }
                .map { String($0.prefix(90)) }
            return LauncherItem(
                id: "note.\(note.id)", title: note.title, subtitle: body ?? "Empty note",
                symbol: "note.text", kind: .note, badge: "Note", keywords: note.content, action: .note(note))
        }
    }

    nonisolated static let aiCommandSubtitle = "Uses your selected text"

    /// A snippet or note found by its keyword or text, not its name, says why it
    /// matched. Only rows that survived scoring get here, so typing never reads
    /// the bodies of rows that are filtered out.
    nonisolated static func explainingMatch(_ item: LauncherItem, query term: String) -> LauncherItem {
        var item = item
        switch item.action {
        case .snippet(let snippet) where SearchMatcher.score(term, in: snippet.name) == nil:
            if !snippet.keyword.isEmpty, (SearchMatcher.score(term, in: snippet.keyword) ?? 0) >= 450 {
                item.subtitle = "Keyword match · \(item.subtitle)"
            } else if let excerpt = matchingExcerpt(of: snippet.content, query: term) {
                item.subtitle = excerpt
            }
        case .note(let note) where SearchMatcher.score(term, in: note.title) == nil:
            if let excerpt = matchingExcerpt(of: note.content, query: term) { item.subtitle = excerpt }
        case .ai(let action) where action != .chat && SearchMatcher.score(term, in: item.title) == nil:
            // Found by what it does (“…meeting notes”), so say that instead of the generic line.
            // An unavailable command keeps saying so.
            if item.subtitle == aiCommandSubtitle, SearchMatcher.score(term, in: action.subtitle) != nil {
                item.subtitle = action.subtitle
            }
        default: break
        }
        return item
    }

    /// The first line of `text` containing a query term, cut to about 90
    /// characters around the match. It reads only the window SearchMatcher
    /// scores, so a match it could show is a match that ranked the row.
    nonisolated static func matchingExcerpt(of text: String, query: String) -> String? {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nil }
        for rawLine in SearchMatcher.scoredWindow(of: text).split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for term in terms {
                guard let match = line.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    continue
                }
                guard line.count > 90 else { return line }
                let offset = line.distance(from: line.startIndex, to: match.lowerBound)
                let start = line.index(line.startIndex, offsetBy: max(0, min(offset - 30, line.count - 90)))
                let end = line.index(start, offsetBy: 90, limitedBy: line.endIndex) ?? line.endIndex
                let excerpt = String(line[start..<end])
                return (start > line.startIndex ? "…" : "") + excerpt + (end < line.endIndex ? "…" : "")
            }
        }
        return nil
    }

    var windowItems: [LauncherItem] {
        // The design system's grid order: halves, quarters, then the rest.
        let layouts: [WindowLayout] = [
            .leftHalf, .rightHalf, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight,
            .maximize, .center, .nextDisplay, .restore,
        ]
        return layouts.map { layout in
            LauncherItem(
                id: "window.\(layout.id)", title: layout.title,
                subtitle: accessibilityAllowed ? "Window layout" : "Needs Accessibility. Press ↩ to enable",
                symbol: layout.symbol, kind: .window, badge: "Window", keywords: "window resize move tile",
                action: .window(layout))
        }
    }

    var commandItems: [LauncherItem] {
        var commands = [
            LauncherItem(
                id: "ai.chat", title: "Ask AI", subtitle: "Think, write and brainstorm on this Mac",
                symbol: "sparkles", kind: .ai, badge: "AI", keywords: "chat assistant write apple intelligence",
                action: .ai(.chat))
        ]
        commands += LauncherSection.allCases.filter { $0 != .home }.map { section in
            LauncherItem(
                id: "section.\(section.id)", title: section.title, subtitle: section.summary,
                symbol: section.tileSymbol, kind: section.kind, badge: "Command",
                keywords: "search " + section.title, action: .section(section))
        }
        commands += AIAction.allCases.filter { $0 != .chat }.map { action in
            LauncherItem(
                id: "ai.\(action.id)", title: action.title,
                subtitle: ai.availability.isAvailable ? Self.aiCommandSubtitle : "Not available yet",
                symbol: action.kindSymbol, kind: .ai, badge: "AI command", keywords: "AI writing text " + action.subtitle,
                action: .ai(action))
        }
        commands += windowItems
        commands.append(
            LauncherItem(
                id: "settings", title: "Settings", subtitle: "Shortcuts, clipboard, permissions and more",
                symbol: "gearshape", kind: .system, badge: "Command",
                keywords: "openray settings preferences permissions shortcut", action: .settings))
        return commands
    }

    nonisolated static func fileKind(_ url: URL) -> String {
        if url.hasDirectoryPath { return "Folder" }
        let ext = url.pathExtension.uppercased()
        switch ext {
        case "": return "File"
        case "KEY": return "Keynote"
        case "PAGES": return "Pages"
        case "NUMBERS": return "Numbers"
        case "MD": return "Markdown"
        case "TXT": return "Text"
        case "JPG", "JPEG", "PNG", "HEIC", "GIF", "TIFF": return "Image"
        default: return ext.count <= 5 ? ext : "File"
        }
    }

    // MARK: - Accessories

    /// Alias or keyword chip for a row, if any.
    func aliasChip(for item: LauncherItem) -> String? {
        switch item.action {
        case .snippet(let snippet): snippet.keyword.isEmpty ? nil : snippet.keyword
        // Retarget rows show their keyword; the primary argument row and fallbacks don't.
        case .quicklink(let link, _)
        where item.id != argumentLink.map({ "argument.\($0.id)" }) && !item.id.hasPrefix("fallback."):
            link.keyword.isEmpty ? nil : link.keyword
        default: store.database.binding(for: item.id)?.alias
        }
    }

    func boundShortcut(for item: LauncherItem) -> CommandShortcut? {
        store.database.binding(for: item.id)?.shortcut
    }

    func isFavorite(_ item: LauncherItem) -> Bool { store.database.favoriteIDs.contains(item.id) }

    /// The ⌘-number for an argument retarget (⌘2–⌘8). Favorite tiles number themselves
    /// by their place in the strip, which is the order performNumber uses.
    func numberShortcut(for item: LauncherItem) -> Int? {
        guard argumentLink != nil else { return nil }
        let items = orderedResults
        guard let index = items.firstIndex(where: { $0.id == item.id }), index > 0, index < 8 else { return nil }
        return index + 1
    }
}
