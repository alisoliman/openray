import AppKit
import SwiftUI

struct LauncherSearchView: View {
    @Bindable var model: LauncherModel
    @State private var deletion: LauncherItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var scopeSelection
    @Namespace private var resultSelection

    var body: some View {
        let groups = model.groups
        let items = groups.flatMap(\.items)
        let selected = items.first(where: { $0.id == model.selectedID }) ?? items.first
        return VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.6)
            scopeBar
            if model.section == .clipboard || [.snippets, .quicklinks, .notes].contains(model.section) {
                sectionTools
            }
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
                move: model.moveSelection, cancel: model.goBack, paste: model.pasteSelected,
                enterAI: model.quickAI
            )
            .frame(maxWidth: .infinity)
            if model.files.isSearching || model.applications.isLoading
                || (model.section == .clipboard && model.clipboard.isProcessing)
            {
                ProgressView().controlSize(.small).accessibilityLabel("Searching")
            } else if !model.query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { model.query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if model.section == .home {
                Button {
                    _ = model.quickAI()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Ask AI").fontWeight(.medium)
                        Keycap(text: "⇥")
                    }
                    .font(.system(size: 12)).foregroundStyle(.purple)
                    .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
                    .background(.purple.opacity(0.09), in: .rect(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.purple.opacity(0.13)) }
                }
                .buttonStyle(RayControlStyle()).help("Open AI with your search text (Tab)")
                .accessibilityLabel("Open AI workspace, Tab").accessibilityIdentifier("launcher.quickAI")
            } else {
                Keycap(text: "esc")
            }
        }.padding(.horizontal, 22).frame(height: 72)
    }

    private var scopeBar: some View {
        HStack(spacing: 4) {
            scopeButton("All", symbol: "square.grid.2x2", section: .home, shortcut: "1")
            scopeButton("Apps", symbol: "app", section: .applications, shortcut: "2")
            scopeButton("Files", symbol: "folder", section: .files, shortcut: "3")
            scopeButton("Clipboard", symbol: "clipboard", section: .clipboard, shortcut: "4")
            scopeButton("Notes", symbol: "note.text", section: .notes, shortcut: "5")
            Menu {
                ForEach([LauncherSection.snippets, .quicklinks, .windows, .calculator]) { section in
                    Button(section.title, systemImage: section.symbol) { model.navigate(to: section) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(
                        [.snippets, .quicklinks, .windows, .calculator].contains(model.section)
                            ? model.section.title : "More")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(
                    [.snippets, .quicklinks, .windows, .calculator].contains(model.section)
                        ? Color.primary.opacity(0.075) : .clear, in: .rect(cornerRadius: 7))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                .accessibilityIdentifier("launcher.moreFeatures")
            Spacer(minLength: 8)
            Button {
                model.openAI()
            } label: {
                Label("AI", systemImage: "sparkles").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 7).foregroundStyle(.purple)
            }.buttonStyle(RayControlStyle()).help("AI workspace (⌘6)")
        }
        .padding(.horizontal, 14).frame(height: 46)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: model.section)
    }

    private var sectionTools: some View {
        HStack(spacing: 8) {
            Text(model.section.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if model.section == .clipboard {
                Picker("Clipboard content type", selection: $model.clipboardFilter) {
                    ForEach(ClipboardFilter.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().controlSize(.small).accessibilityIdentifier("clipboard.filter")
            } else {
                Button {
                    model.createItem()
                } label: {
                    HStack(spacing: 6) {
                        Label("Create New", systemImage: "plus")
                        Keycap(text: "⌘ N")
                    }.font(.system(size: 11, weight: .medium))
                }.buttonStyle(RayControlStyle()).foregroundStyle(RayStyle.accent)
                    .accessibilityIdentifier("library.create")
            }
        }.padding(.horizontal, 22).frame(height: 34)
    }

    private func scopeButton(_ title: String, symbol: String, section: LauncherSection, shortcut: String) -> some View {
        let selected = model.section == section
        return Button {
            model.navigate(to: section)
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .foregroundStyle(selected ? Color.primary : .secondary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.075))
                            .matchedGeometryEffect(id: "scope", in: scopeSelection)
                    }
                }
        }.buttonStyle(RayControlStyle()).help("\(title) (⌘\(shortcut))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("scope.\(section.id)")
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
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 13)
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
                        Text(group.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(item.badge).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if selected { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 10).frame(height: 53)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(.primary.opacity(0.075))
                            .overlay(alignment: .leading) {
                                Capsule().fill(RayStyle.accent).frame(width: 3, height: 18).padding(.leading, 1)
                            }
                            .matchedGeometryEffect(id: "result", in: resultSelection)
                    }
                }
                .contentShape(.rect)
                .animation(reduceMotion ? nil : .spring(response: 0.23, dampingFraction: 0.9), value: model.selectedID)
        }
        .buttonStyle(RayControlStyle()).accessibilityLabel(item.accessibilityDescription)
        .accessibilityValue(item.subtitle).accessibilityHint(
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
                    title: Calculator.issue(for: model.query)?.title ?? "A little less mental math",
                    detail: Calculator.issue(for: model.query)?.message
                        ?? "Arithmetic, percentages, scientific functions, and conversions for length, mass, time, temperature, volume, and storage. Try an example below."
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
            } else if model.section == .clipboard && (!model.query.isEmpty || model.clipboardFilter != .all) {
                EmptyState(
                    symbol: "line.3.horizontal.decrease.circle", title: "No matching clipboard items",
                    detail: "Try a different search or show all content types. Your saved history is still available."
                )
                HStack(spacing: 12) {
                    if !model.query.isEmpty {
                        Button("Clear Search") {
                            model.query = ""
                            model.focusRequest += 1
                        }.buttonStyle(.bordered)
                    }
                    if model.clipboardFilter != .all {
                        Button("Show All Types") { model.clipboardFilter = .all }.buttonStyle(.bordered)
                    }
                }
            } else if !model.query.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass", title: "No matching results",
                    detail: model.section == .home
                        ? "Try a different name or keyword. You can also search the web with a quicklink, such as “web \(model.query)”."
                        : "Try a different name or keyword, or clear your search to see all \(model.section.title.lowercased())."
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
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9))
                Text("Navigate").font(.system(size: 10))
            }.foregroundStyle(.tertiary).padding(.leading, 8).accessibilityHidden(true)
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
            }.buttonStyle(.plain).accessibilityIdentifier("launcher.actions")
                .background {
                    NativeActionsMenu(
                        isPresented: $model.showActions,
                        title: selected?.title ?? "OpenRay",
                        entries: actionEntries(for: selected),
                        didClose: { model.focusRequest += 1 }
                    )
                    .accessibilityHidden(true)
                }
        }.padding(.horizontal, 18).frame(height: 43)
    }

    private func actionEntries(for item: LauncherItem?) -> [NativeActionsMenu.Entry] {
        var entries: [NativeActionsMenu.Entry] = []
        if let item {
            entries.append(.init(title: item.primaryActionTitle, symbol: "return") { model.perform(item) })
            if item.supportsPaste {
                entries.append(
                    .init(title: "Paste into Previous App", symbol: "arrow.up.doc") {
                        model.showActions = false
                        model.selectedID = item.id
                        guard model.selectedItem?.id == item.id else { return }
                        model.pasteSelected()
                    })
            }
            if let text = item.copyText {
                entries.append(.init(title: "Copy", symbol: "doc.on.doc") { model.copy(text) })
            }
            if item.canFavorite {
                entries.append(
                    .init(
                        title: model.store.database.favoriteIDs.contains(item.id)
                            ? "Remove from Favorites" : "Add to Favorites", symbol: "star"
                    ) { model.store.toggleFavorite(item.id) })
            }
            switch item.action {
            case .quicklink, .snippet, .note:
                entries.append(
                    .init(title: "Edit", symbol: "pencil") {
                        model.selectedID = item.id
                        guard model.selectedItem?.id == item.id else { return }
                        model.editSelected()
                    })
                entries.append(.init(title: "Delete…", symbol: "trash") { deletion = item })
            case .clipboard:
                entries.append(.init(title: "Delete…", symbol: "trash") { deletion = item })
            case .file(let url):
                entries.append(
                    .init(title: "Reveal in Finder", symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    })
            case .application(let app):
                entries.append(
                    .init(title: "Reveal in Finder", symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    })
            default: break
            }
        }
        entries.append(.init(title: "Settings", symbol: "gearshape") { model.openSettings() })
        entries.append(.init(title: "Back to Everything", symbol: "magnifyingglass") { model.navigate(to: .home) })
        return entries
    }
}

private struct ItemPreview: View {
    var item: LauncherItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PREVIEW").font(.system(size: 11, weight: .semibold)).tracking(1)
                Spacer()
                Text(metadata).font(.system(size: 11))
            }.foregroundStyle(.secondary)
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
                                    Text(url.deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(
                                        .secondary)
                                }.textSelection(.enabled)
                            } icon: {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("File references only. Originals aren’t duplicated or modified.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(item.copyText ?? item.subtitle).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if case .clipboard(let entry) = item.action {
                Divider()
                Text(entry.sourceName).font(.system(size: 11, weight: .medium))
                Text(entry.copiedAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
