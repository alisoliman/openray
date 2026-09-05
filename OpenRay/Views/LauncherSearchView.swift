import AppKit
import SwiftUI

struct LauncherSearchView: View {
    @Bindable var model: LauncherModel
    @State private var deletion: LauncherItem?

    var body: some View {
        let groups = model.groups
        let items = groups.flatMap(\.items)
        let selected = items.first(where: { $0.id == model.selectedID }) ?? items.first
        return VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.6)
            scopeBar
            if let message = model.message ?? model.store.errorMessage ?? model.shortcutError {
                StatusBanner(message: message) { model.message = nil }
            }
            if model.section == .clipboard, !model.store.database.preferences.clipboardEnabled,
                !model.store.database.clipboard.isEmpty
            {
                StatusBanner(
                    message: "Capture is paused. Your saved history is still available. Resume capture in Settings.")
            }
            if model.section == .clipboard, let note = model.clipboard.accessMessage {
                StatusBanner(message: note)
            }
            if model.section == .clipboard, let note = model.clipboard.contentMessage {
                StatusBanner(message: note)
            }
            content(groups: groups, selected: selected).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.6)
            footer(selected: selected)
        }
        .onChange(of: items.map(\.id), initial: true) { model.synchronizeSelection() }
        .background {
            Group {
                Button("Actions") { model.showActions.toggle() }.keyboardShortcut("k")
                Button("New Item") { model.createItem() }.keyboardShortcut("n")
                Button("Paste Selected Result") { model.pasteSelected() }.keyboardShortcut(.return, modifiers: .command)
            }.hidden()
        }
        .alert(
            "Delete \(deletion?.title ?? "item")?",
            isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { deletion = nil }
            Button("Delete", role: .destructive) {
                if let deletion { model.delete(deletion) }
                deletion = nil
            }
        } message: {
            Text("This removes the saved item from OpenRay’s local library. This cannot be undone.")
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 14) {
            if model.section != .home {
                BackButton { model.navigate(to: .home) }
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 21)).foregroundStyle(.secondary)
            }
            LauncherSearchInput(
                text: $model.query, placeholder: model.section.placeholder,
                focusRequest: model.focusRequest, submit: model.performSelected,
                move: model.moveSelection, cancel: model.goBack, paste: model.pasteSelected
            )
            .frame(maxWidth: .infinity)
            if model.files.isSearching || model.applications.isLoading
                || (model.section == .clipboard && model.clipboard.isProcessing)
            {
                ProgressView().controlSize(.small).accessibilityLabel("Searching")
            } else if !model.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { model.query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            Keycap(text: "esc")
        }.padding(.horizontal, 22).frame(height: 72)
    }

    private var scopeBar: some View {
        HStack(spacing: 7) {
            if model.section == .home {
                scopeButton("All", symbol: "square.grid.2x2", selected: true) {}
                scopeButton("Apps", symbol: "app") { model.navigate(to: .applications) }
                scopeButton("Files", symbol: "folder") { model.navigate(to: .files) }
                scopeButton("Ask AI", symbol: "sparkles") { model.openAI() }
            } else {
                Label(model.section.title, systemImage: model.section.symbol)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.section == .clipboard {
                Picker("Clipboard content type", selection: $model.clipboardFilter) {
                    ForEach(ClipboardFilter.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().controlSize(.small).accessibilityIdentifier("clipboard.filter")
            }
            if [.snippets, .quicklinks, .notes].contains(model.section) {
                Button {
                    model.createItem()
                } label: {
                    Label("Create New", systemImage: "plus").font(.system(size: 12, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(RayStyle.accent).accessibilityIdentifier("library.create")
            } else {
                HStack(spacing: 5) {
                    Circle().fill(.green.opacity(0.8)).frame(width: 5, height: 5)
                    Text("LOCAL & PRIVATE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.6)
                }.foregroundStyle(.tertiary).accessibilityLabel("Local and private")
            }
        }.padding(.horizontal, 18).frame(height: 44)
    }

    private func scopeButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(selected ? Color.primary : .secondary)
                .background(selected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func content(groups: [LauncherResultGroup], selected: LauncherItem?) -> some View {
        if model.section == .clipboard && !model.store.database.preferences.clipboardEnabled
            && model.store.database.clipboard.isEmpty
        {
            VStack(spacing: 0) {
                EmptyState(
                    symbol: "lock.shield", title: "Your clipboard, on your terms",
                    detail:
                        "Save copied text, images, and file references locally so you can find them later. Known password-manager apps and content marked confidential are excluded. Capture stays off until you enable it."
                )
                Button("Enable Clipboard History") {
                    if model.store.update({
                        $0.preferences.clipboardEnabled = true
                        $0.preferences.clipboardImagesEnabled = true
                        $0.preferences.clipboardFilesEnabled = true
                    }) {
                        model.applyPreferences()
                    }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Text("You can pause capture or delete your history at any time.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 13)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.allSatisfy({ $0.items.isEmpty }) {
            emptyState
        } else {
            HStack(spacing: 0) {
                resultList(groups: groups, selectedID: selected?.id)
                if [.clipboard, .snippets, .notes].contains(model.section), let selected {
                    Divider().opacity(0.5)
                    ItemPreview(item: selected).frame(width: 285)
                }
            }
        }
    }

    private func resultList(groups: [LauncherResultGroup], selectedID: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(groups) { group in
                        Text(group.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 5)
                        ForEach(group.items) { item in resultRow(item, selected: item.id == selectedID).id(item.id) }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }.onChange(of: model.selectedID) {
                if let selectedID = model.selectedID { proxy.scrollTo(selectedID) }
            }
        }
    }

    private func resultRow(_ item: LauncherItem, selected: Bool) -> some View {
        return Button {
            model.selectedID = item.id
            model.perform(item)
        } label: {
            HStack(spacing: 12) {
                ItemIcon(item: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.store.database.favoriteIDs.contains(item.id) {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                Text(item.badge).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                if selected { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).frame(height: 53)
                .background(selected ? Color.primary.opacity(0.075) : .clear, in: .rect(cornerRadius: 8)).contentShape(
                    .rect)
        }
        .buttonStyle(.plain).accessibilityLabel("\(item.title), \(item.badge)").accessibilityHint(
            item.primaryActionTitle
        )
        .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("result.\(item.id)")
        .contextMenu {
            Button(item.primaryActionTitle) { model.perform(item) }
            if item.canFavorite {
                Button(
                    model.store.database.favoriteIDs.contains(item.id) ? "Remove from Favorites" : "Add to Favorites"
                ) {
                    model.store.toggleFavorite(item.id)
                }
            }
            if let text = item.copyText { Button("Copy") { model.copy(text) } }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 0) {
            if model.section == .calculator {
                EmptyState(
                    symbol: "equal.square",
                    title: model.query.isEmpty ? "A little less mental math" : "Check that expression",
                    detail:
                        "Arithmetic, percentages, scientific functions, and conversions for length, mass, time, temperature, volume, and storage. Currency rates and natural-language dates aren’t supported yet."
                )
                HStack(spacing: 8) {
                    ForEach(["(120 + 45) * 0.2", "10 km in mi", "72 f in c"], id: \.self) { example in
                        Button(example) {
                            model.query = example
                            model.focusRequest += 1
                        }
                        .font(.system(size: 11, design: .monospaced)).buttonStyle(.bordered)
                    }
                }
            } else if model.section == .files {
                EmptyState(
                    symbol: "folder.badge.magnifyingglass",
                    title: model.files.isSearching ? "Searching your Mac…" : "No files found",
                    detail: model.files.errorMessage
                        ?? "Search by filename using at least two characters. OpenRay uses Spotlight in your home folder and excludes Library. Check Spotlight indexing and folder permissions if files are missing."
                )
            } else if !model.query.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass", title: "No matching results",
                    detail:
                        "Try a different name or keyword. You can also search the web with a quicklink, such as “web \(model.query)”."
                )
            } else if model.section == .clipboard {
                EmptyState(
                    symbol: "clipboard", title: "Ready when you copy",
                    detail:
                        "Copy text, an image, or files in another app and they will appear here. Your history is stored only on this Mac."
                )
            } else if [.snippets, .quicklinks, .notes].contains(model.section) {
                EmptyState(
                    symbol: model.section.symbol, title: "A little less repetition",
                    detail:
                        "Create your first \(model.section == .notes ? "note" : model.section == .snippets ? "snippet" : "quicklink") and find it instantly from the launcher."
                )
                Button("Create New") { model.createItem() }.buttonStyle(.borderedProminent)
            } else {
                EmptyState(
                    symbol: "app.dashed",
                    title: model.applications.isLoading ? "Finding your apps…" : "Nothing here yet",
                    detail:
                        "OpenRay looks in your Applications folders. Refresh the app index in Settings if an app is missing."
                )
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(selected: LauncherItem?) -> some View {
        HStack(spacing: 9) {
            OpenRayMark(size: 18)
            Text(model.clipboard.usesGeneralPasteboard ? "OpenRay" : "OpenRay · Verification")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if let item = selected {
                Button {
                    model.perform(item)
                } label: {
                    HStack(spacing: 8) {
                        Text(item.primaryActionTitle).font(.system(size: 11, weight: .medium))
                        Keycap(text: "↩")
                    }
                }.buttonStyle(.plain)
                Divider().frame(height: 16).padding(.horizontal, 5)
            }
            Button {
                model.showActions.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("Actions").font(.system(size: 11, weight: .medium))
                    Keycap(text: "⌘ K")
                }
            }.buttonStyle(.plain)
                .popover(isPresented: $model.showActions, arrowEdge: .bottom) {
                    ActionsView(model: model) { item in
                        model.showActions = false
                        deletion = item
                    }
                }
        }.padding(.horizontal, 18).frame(height: 43)
    }
}

private struct ItemPreview: View {
    var item: LauncherItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PREVIEW").font(.system(size: 9, weight: .semibold)).tracking(1)
                Spacer()
                Text(metadata).font(.system(size: 10))
            }.foregroundStyle(.tertiary)
            if let resource = item.clipboardImage {
                ClipboardImageView(resource: resource)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .clipboard(let entry) = item.action, case .files(let files) = entry.content {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(files, id: \.absoluteString) { url in
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                                    Text(url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(
                                        .secondary)
                                }.textSelection(.enabled)
                            } icon: {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("File references only. Originals aren’t duplicated or modified.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    Text(item.copyText ?? item.subtitle).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if case .clipboard(let entry) = item.action {
                Divider()
                Text(entry.sourceName).font(.system(size: 11, weight: .medium))
                Text(entry.copiedAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }.padding(18).background(.primary.opacity(0.015))
    }

    private var metadata: String {
        if case .clipboard(let entry) = item.action {
            switch entry.content {
            case .image(let image):
                return ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file)
            case .files(let urls): return "\(urls.count) file reference\(urls.count == 1 ? "" : "s")"
            case .text(let text): return "\(text.count.formatted()) characters"
            }
        }
        return "\((item.copyText ?? "").count.formatted()) characters"
    }
}

private struct ActionsView: View {
    @Bindable var model: LauncherModel
    var delete: (LauncherItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.selectedItem?.title ?? "OpenRay").font(.system(size: 11, weight: .semibold)).foregroundStyle(
                .secondary
            ).padding(8)
            if let item = model.selectedItem {
                action(item.primaryActionTitle, "return") { model.perform(item) }
                if item.supportsPaste {
                    action("Paste into Previous App", "arrow.up.doc") {
                        model.showActions = false
                        model.pasteSelected()
                    }
                }
                if let text = item.copyText {
                    action("Copy", "doc.on.doc") {
                        model.copy(text)
                        model.showActions = false
                    }
                }
                if item.canFavorite {
                    action(
                        model.store.database.favoriteIDs.contains(item.id)
                            ? "Remove from Favorites" : "Add to Favorites", "star"
                    ) {
                        model.store.toggleFavorite(item.id)
                        model.showActions = false
                    }
                }
                switch item.action {
                case .quicklink, .snippet, .note:
                    action("Edit", "pencil") { model.editSelected() }
                    action("Delete…", "trash") { delete(item) }
                case .clipboard: action("Delete…", "trash") { delete(item) }
                case .file(let url):
                    action("Reveal in Finder", "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        model.showActions = false
                    }
                case .application(let app):
                    action("Reveal in Finder", "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                        model.showActions = false
                    }
                default: EmptyView()
                }
                Divider().padding(.vertical, 5)
            }
            action("Settings", "gearshape") { model.openSettings() }
            action("Back to Everything", "magnifyingglass") { model.navigate(to: .home) }
        }.padding(8).frame(width: 270)
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(.rect)
        }.buttonStyle(.plain)
    }
}
