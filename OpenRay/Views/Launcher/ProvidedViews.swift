import SwiftUI

// Views for rows and scopes that registered providers supply. Providers draw a grid tile's
// content with a `GridTileRenderer`; the launcher draws everything around it here.

/// A grid tile for a group with a `tile` renderer: selection fill, hover, click, context menu
/// and VoiceOver around the provider's content. Unlike window layout tiles, it never dims for
/// Accessibility; a row that can't run says so with the `.unavailable` trait.
struct ProvidedGridTile: View {
    let model: LauncherModel
    let item: LauncherItem
    var selected: Bool
    var renderer: GridTileRenderer
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedID = item.id
            model.perform(item)
        } label: {
            renderer.render(item, selected)
                .opacity(isUnavailable ? 0.5 : 1)
                .padding(.horizontal, 6).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? OR.Color.fill2 : hovering ? OR.Color.fill1 : .clear,
                    in: .rect(cornerRadius: OR.Radius.row, style: .continuous)
                )
                .contentShape(.rect(cornerRadius: OR.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.accessibilityDescription)
        .accessibilityHint(model.primaryTitle(for: item))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("result.\(item.id)")
        .contextMenu { ActionContextMenu(model: model, item: item) }
    }

    private var isUnavailable: Bool {
        if case .provided(let ref) = item.action { return ref.has(.unavailable) }
        return false
    }
}

/// `GridTileRenderer.standard`: the row's glyph over its title.
struct StandardGridTile: View {
    let item: LauncherItem

    var body: some View {
        VStack(spacing: 7) {
            ItemGlyph(item: item, size: 32)
            Text(item.title).font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text)
                .lineLimit(1).truncationMode(.tail)
        }
    }
}

/// An empty provided scope: the provider's words, or `LauncherModel.providedEmptyState(for:)`'s.
struct ProvidedScopeEmptyState: View {
    let model: LauncherModel
    let scope: ProvidedScope

    var body: some View {
        let state = model.providedEmptyState(for: scope)
        EmptyStateView(kind: scope.kind, symbol: state.symbol ?? scope.symbol, title: state.title, detail: state.detail) {
            if !model.query.isEmpty {
                Button("Clear Search") {
                    model.query = ""
                    model.focusRequest += 1
                }
                .buttonStyle(.or(.secondary, large: true))
            }
        }
    }
}
