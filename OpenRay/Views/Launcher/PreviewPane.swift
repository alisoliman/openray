import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The pane beside a two-line list: media or text, then label–value metadata.
struct PreviewPane: View {
    let model: LauncherModel
    let item: LauncherItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if !metadata.isEmpty {
                Hairline()
                MetaTable(rows: metadata)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        .frame(width: OR.Metric.preview)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Hairline(vertical: true) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview")
    }

    @ViewBuilder private var content: some View {
        switch item.action {
        case .clipboard(let entry):
            header(entry.kindTitle, detail: clipboardDetail(entry))
            switch entry.content {
            case .image:
                if let resource = item.clipboardImage {
                    ClipboardImageView(resource: resource)
                        .frame(maxWidth: .infinity, maxHeight: 250)
                        .padding(8)
                        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous).strokeBorder(OR.Color.separator)
                        }
                }
            case .files(let urls):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(urls, id: \.absoluteString) { url in
                            HStack(spacing: 10) {
                                WorkspaceIcon(url: url, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
                                    Text(LauncherModel.shortenedPath(url.deletingLastPathComponent())).font(OR.Font.callout)
                                        .foregroundStyle(OR.Color.text2)
                                }
                                .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                Text("References only. Originals are never copied or changed.")
                    .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            case .text(let text):
                textBox(text, mono: entry.isLink)
            }
        case .snippet(let snippet):
            // The keyword is in the metadata below, so the header counts what gets pasted, as clipboard text does.
            let expanded = snippet.expanded()
            header("Preview", detail: "\(expanded.count.formatted()) character\(expanded.count == 1 ? "" : "s")")
            textBox(expanded, mono: false)
        case .note(let note):
            Text(note.title).font(OR.Font.title).foregroundStyle(OR.Color.text).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if note.content.split(whereSeparator: \.isNewline).allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0 == note.title }) {
                Text("Empty note").font(.system(size: 12.5)).foregroundStyle(OR.Color.text3)
            } else {
                // Sized to the note, so the metadata follows it as in the other previews.
                ScrollView {
                    Text(note.content).font(.system(size: 12.5)).lineSpacing(5).foregroundStyle(OR.Color.text)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                // Fits the full detent with a two-line title and the metadata below.
                .frame(maxHeight: 300, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .quicklink(let link, _):
            header(link.needsQuery ? "Search template" : "Link", detail: nil)
            QuicklinkTemplateText(template: link.template)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
            if link.needsQuery {
                Text("Type “\(link.keyword.isEmpty ? link.name : link.keyword)” and a space in Everything to search it.")
                    .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
        case .file(let url):
            FileThumbnail(url: url)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(OR.Font.bodyEmphasis).foregroundStyle(OR.Color.text).lineLimit(2)
                Text(FileFacts(url: url).kind).font(OR.Font.callout).foregroundStyle(OR.Color.text2)
            }
        case .provided(let ref):
            if let content = model.registry.preview(for: item, ref: ref, in: model)?.content { content }
        default:
            EmptyView()
        }
    }

    private func header(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let detail { Text(detail).lineLimit(1) }
        }
        .font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text2)
    }

    private func textBox(_ text: String, mono: Bool) -> some View {
        ScrollView {
            Text(text).font(mono ? OR.Font.mono : .system(size: 12.5)).lineSpacing(4)
                .foregroundStyle(OR.Color.text)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxHeight: 260, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.row, style: .continuous))
    }

    private func clipboardDetail(_ entry: ClipboardEntry) -> String? {
        switch entry.content {
        case .image(let image): "\(image.pixelWidth) × \(image.pixelHeight)"
        case .text(let text): "\(text.count.formatted()) characters"
        case .files(let urls): urls.count == 1 ? nil : "\(urls.count) files"
        }
    }

    private var metadata: [(String, String)] {
        switch item.action {
        case .clipboard(let entry):
            var rows = [("Copied from", entry.sourceName), ("Copied", Self.relativeDay(entry.copiedAt))]
            if case .image(let image) = entry.content {
                rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file) + " PNG"))
                if let text = entry.recognizedText, !text.isEmpty {
                    rows.append(("Text", String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))))
                }
            }
            let formats = ClipboardPayload.formats(for: entry).filter { $0 == .rtf || $0 == .html }
            if !formats.isEmpty {
                rows.append(("Formats", (["Plain"] + formats.map { $0 == .rtf ? "RTF" : "HTML" }).joined(separator: ", ")))
            }
            rows.append(("Expires", expiry(entry)))
            return rows
        case .snippet(let snippet):
            var rows = [
                ("Keyword", snippet.keyword.isEmpty ? "None" : snippet.keyword),
                ("Expands as you type", expansion(of: snippet)),
            ]
            let arguments = snippet.dynamicTemplate?.arguments ?? []
            if !arguments.isEmpty { rows.append(("Asks for", arguments.map(\.title).joined(separator: ", "))) }
            if !snippet.tagList.isEmpty { rows.append(("Tags", snippet.tagList.joined(separator: ", "))) }
            return rows
        case .note(let note):
            return [("Edited", Self.relativeDay(note.modifiedAt)), ("Words", note.wordCount.formatted())]
        case .quicklink(let link, _):
            return [("Keyword", link.keyword.isEmpty ? "None" : link.keyword), ("Opens in", model.openerName(for: link))]
        case .file(let url):
            let facts = FileFacts(url: url)
            var rows = [("Where", facts.location)]
            if let size = facts.size { rows.append(("Size", size)) }
            if let modified = facts.modified { rows.append(("Modified", Self.relativeDay(modified))) }
            if let count = model.store.database.usage.first(where: { $0.id == item.id })?.count {
                rows.append(("Opened", "\(count) time\(count == 1 ? "" : "s") from OpenRay"))
            }
            return rows
        case .provided(let ref):
            return model.registry.preview(for: item, ref: ref, in: model)?.metadata.map { ($0.label, $0.value) } ?? []
        default: return []
        }
    }

    /// What actually happens when the keyword is typed, in the order the editor explains it.
    private func expansion(of snippet: Snippet) -> String {
        if snippet.keyword.isEmpty { return "No keyword" }
        if !snippet.expandsAsYouType { return "Off" }
        if !model.accessibilityAllowed { return "Needs Accessibility" }
        if !model.store.database.preferences.snippetExpansionEnabled { return "Off for all snippets" }
        return "On"
    }

    private func expiry(_ entry: ClipboardEntry) -> String {
        if entry.isPinned { return "Never · Pinned" }
        guard let days = model.store.database.preferences.clipboardRetentionDaysOrUnlimited else { return "Never" }
        let date = entry.copiedAt.addingTimeInterval(Double(days) * 86_400)
        let remaining = date.timeIntervalSinceNow
        if remaining < 3_600 { return "Within the hour" }
        if remaining < 86_400 { return "In \(Int(remaining / 3_600)) h" }
        let count = Int((remaining / 86_400).rounded(.up))
        return "In \(count) day\(count == 1 ? "" : "s")"
    }

    static func relativeDay(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// Shows {query} as an accent chip inside a template.
struct QuicklinkTemplateText: View {
    var template: String

    var body: some View {
        var string = AttributedString()
        let parts = template.components(separatedBy: "{query}")
        for (index, part) in parts.enumerated() {
            var run = AttributedString(part)
            run.foregroundColor = OR.Color.text
            string += run
            if index < parts.count - 1 {
                var placeholder = AttributedString("{query}")
                placeholder.foregroundColor = OR.Color.accent
                placeholder.font = .system(size: 12, weight: .semibold, design: .monospaced)
                string += placeholder
            }
        }
        return Text(string).font(OR.Font.mono).lineLimit(4)
    }
}

struct FileFacts {
    var url: URL

    var kind: String {
        (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? "File"
    }

    var size: String? {
        guard !url.hasDirectoryPath,
            let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var modified: Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }

    /// The path as a breadcrumb: Documents › Planning. Deep paths keep the first
    /// folder and the last two, so shortening never cuts a folder name in half.
    var location: String {
        let parent = LauncherModel.shortenedPath(url.deletingLastPathComponent())
        let folders = parent.split(separator: "/").filter { $0 != "~" }.map(String.init)
        let shown = folders.count > 3 ? [folders[0], "…"] + folders.suffix(2) : folders
        return shown.joined(separator: " › ").ifEmpty("Home")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// A real Quick Look thumbnail, falling back to the file icon.
struct FileThumbnail: View {
    var url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous).fill(OR.Color.fill1)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
            } else {
                WorkspaceIcon(url: url, size: 64)
            }
        }
        .overlay { RoundedRectangle(cornerRadius: OR.Radius.row, style: .continuous).strokeBorder(OR.Color.separator) }
        .frame(height: 160)
        .task(id: url) {
            image = nil
            guard InertReadBoundary.allows(url) else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 268, height: 150), scale: 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
        .accessibilityHidden(true)
    }
}
