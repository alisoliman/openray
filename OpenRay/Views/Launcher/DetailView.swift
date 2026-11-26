import AppKit
import SwiftUI

// The Detail view: one document in place of the result list, such as a script's full output.
// A provider's scope shows one when the provider conforms to `DetailProviding` and returns
// content for it. The scope's single row stays selected, so ↩, ⌘↩ and ⌘K act on the document.

/// What a detail view shows.
struct DetailContent {
    enum Body: Equatable {
        /// Terminal output with ANSI colors and styles.
        case ansi(String)
        case text(String)
    }

    enum Status: Equatable {
        case running(since: Date)
        case succeeded(String)
        case failed(String)
        case info(String)
    }

    var title: String
    var subtitle: String? = nil
    var symbol = "doc.text"
    var kind: Kind = .command
    /// An emoji shown in place of the symbol tile.
    var emoji: String? = nil
    var status: Status? = nil
    var body: Body
    /// Label–value rows under the document.
    var metadata: [(label: String, value: String)] = []
    /// What an empty body says.
    var emptyText = "No output."
    /// Keeps the newest text in view as the body grows.
    var followsEnd = false
}

/// A provider whose scopes can show a document instead of a list.
@MainActor
protocol DetailProviding: CommandProvider {
    /// The document for one of this provider's scopes, or nil to show the scope's rows as a list.
    func detail(for scope: ProvidedScope, in model: LauncherModel) -> DetailContent?
}

extension LauncherModel {
    /// The current scope's document, when its provider shows one.
    var providedDetail: DetailContent? {
        guard destination == .search, editor == nil, let scope = section.providedScope,
            let provider = registry.provider(id: scope.provider) as? any DetailProviding
        else { return nil }
        return provider.detail(for: scope, in: self)
    }
}

struct DetailView: View {
    let model: LauncherModel
    let content: DetailContent
    @Environment(\.colorScheme) private var colorScheme

    /// The view draws at most this much of the body's end; Copy Output still copies all of it.
    static let renderLimit = 200_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, OR.Space.s4).padding(.vertical, OR.Space.s3)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isEmpty {
                            Text(content.emptyText).font(OR.Font.mono).foregroundStyle(OR.Color.text3)
                        } else {
                            if isClipped {
                                Text("Showing the last \(Self.renderLimit.formatted()) characters.")
                                    .font(OR.Font.caption).foregroundStyle(OR.Color.text3)
                                    .padding(.bottom, OR.Space.s2)
                            }
                            Text(attributedBody)
                                .font(OR.Font.mono)
                                .foregroundStyle(OR.Color.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id("detail.end")
                    }
                    .padding(OR.Space.s4)
                }
                .onChange(of: bodyText) {
                    guard content.followsEnd else { return }
                    proxy.scrollTo("detail.end", anchor: .bottom)
                }
                .onAppear { if content.followsEnd { proxy.scrollTo("detail.end", anchor: .bottom) } }
            }
            if !content.metadata.isEmpty {
                Hairline()
                HStack(spacing: OR.Space.s4) {
                    ForEach(Array(content.metadata.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 4) {
                            Text(entry.label).foregroundStyle(OR.Color.text3)
                            Text(entry.value).foregroundStyle(OR.Color.text2).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(OR.Font.caption)
                .padding(.horizontal, OR.Space.s4).padding(.vertical, OR.Space.s2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minHeight: 400)
        .reportsContentHeight()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
        .accessibilityIdentifier("detail.view")
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: OR.Space.s3) {
            if let emoji = content.emoji {
                Text(emoji).font(.system(size: 20)).frame(width: 28, height: 28)
            } else {
                KindTile(kind: content.kind, symbol: content.symbol, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(OR.Font.title).foregroundStyle(OR.Color.text).lineLimit(1)
                if let subtitle = content.subtitle {
                    Text(subtitle).font(OR.Font.callout).foregroundStyle(OR.Color.text2).lineLimit(1)
                }
            }
            Spacer(minLength: OR.Space.s3)
            if let status = content.status { StatusPill(status: status) }
        }
    }

    private var bodyText: String {
        switch content.body {
        case .ansi(let text), .text(let text): text
        }
    }

    private var isEmpty: Bool { bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isClipped: Bool { bodyText.count > Self.renderLimit }

    private var attributedBody: AttributedString {
        let text = isClipped ? String(bodyText.suffix(Self.renderLimit)) : bodyText
        switch content.body {
        case .text: return AttributedString(text)
        case .ansi: return ANSIRendering.attributed(ANSIText.parse(text))
        }
    }
}

/// Running (with elapsed time), succeeded, failed or a note, as a small pill.
private struct StatusPill: View {
    let status: DetailContent.Status

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .running(let since):
                ProgressView().controlSize(.mini)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Running · \(Int(context.date.timeIntervalSince(since)))s")
                }
            case .succeeded(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(OR.Color.success)
                Text(text)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OR.Color.danger)
                Text(text)
            case .info(let text):
                Image(systemName: "info.circle.fill").foregroundStyle(OR.Color.info)
                Text(text)
            }
        }
        .font(OR.Font.calloutEmphasis)
        .foregroundStyle(OR.Color.text2)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(OR.Color.fill2, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// ANSI spans as an attributed string in OpenRay's palette, adapting to light and dark.
enum ANSIRendering {
    static func attributed(_ spans: [ANSISpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            let style = span.style
            var foreground = style.foreground.map(color(for:))
            var background = style.background.map(color(for:))
            if style.inverse {
                let swapped = foreground ?? SwiftUI.Color(nsColor: OR.NS.text)
                foreground = background ?? SwiftUI.Color(nsColor: OR.NS.panelSolid)
                background = swapped
            }
            if let foreground { piece.foregroundColor = style.dim ? foreground.opacity(0.6) : foreground }
            else if style.dim { piece.foregroundColor = OR.Color.text2 }
            if let background { piece.backgroundColor = background }
            if style.bold || style.italic {
                var font = Font.system(size: 12, weight: style.bold ? .bold : .regular, design: .monospaced)
                if style.italic { font = font.italic() }
                piece.font = font
            }
            if style.underline { piece.underlineStyle = .single }
            if style.strikethrough { piece.strikethroughStyle = .single }
            result += piece
        }
        return result
    }

    static func color(for color: ANSIColor) -> SwiftUI.Color {
        if let rgb = color.rgbComponents {
            return SwiftUI.Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
        }
        switch color.normalized {
        case .standard(let index): return standard[max(0, min(7, index))]
        case .bright(let index): return bright[max(0, min(7, index))]
        default: return OR.Color.text
        }
    }

    private static func pair(_ light: UInt32, _ dark: UInt32) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: OR.NS.dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark)))
    }

    /// Black, red, green, yellow, blue, magenta, cyan, white. Red, green, yellow and blue are
    /// the design system's status colors; the rest are tuned to sit beside them.
    static let standard: [SwiftUI.Color] = [
        pair(0x1D1D22, 0x6E6E78), OR.Color.danger, OR.Color.success, OR.Color.warning, OR.Color.info,
        pair(0xA1288F, 0xE07AD3), pair(0x00808A, 0x5AD7DE), pair(0x8C8C95, 0xDADAE0),
    ]

    static let bright: [SwiftUI.Color] = [
        pair(0x5A5A63, 0x9A9AA4), pair(0xE0453A, 0xFF8A80), pair(0x2E9E4C, 0x7BE58F), pair(0xB87400, 0xFFD27A),
        pair(0x2F7FE0, 0x93C4FF), pair(0xC048B0, 0xF3A3EA), pair(0x14A3AD, 0x8CEBF0), pair(0x55555C, 0xFFFFFF),
    ]
}
