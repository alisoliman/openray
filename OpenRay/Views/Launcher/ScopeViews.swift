import SwiftUI

/// Explains why a scope is empty and offers the most likely next step.
struct ScopeEmptyState: View {
    @Bindable var model: LauncherModel

    var body: some View {
        switch model.section {
        case .calculator:
            if let issue = Calculator.issue(for: model.query) {
                EmptyStateView(kind: .calculator, title: issue.title, detail: issue.message) { examples }
            } else {
                EmptyStateView(
                    kind: .calculator, title: "Less mental math",
                    detail: "Arithmetic, percentages, functions and conversions for length, mass, time, temperature, volume and storage."
                ) { examples }
            }
        case .files:
            if model.files.isSearching {
                EmptyStateView(kind: .file, symbol: "folder", title: "Searching \(model.fileScope.title)…", detail: "Spotlight results appear as they arrive.")
            } else if let error = model.files.errorMessage {
                EmptyStateView(kind: .file, symbol: "folder", title: "Spotlight isn't responding", detail: error)
            } else if model.query.count < 2 {
                EmptyStateView(
                    kind: .file, symbol: "folder", title: "Find a file",
                    detail: "Type two or more letters of a file or folder name. Hidden folders, Library and build products are skipped.")
            } else {
                EmptyStateView(
                    kind: .file, symbol: "folder", title: "No files match “\(model.query.truncatedForFeedback)”",
                    detail: model.fileScope == .home
                        ? "Check the spelling, or that Spotlight indexes your home folder."
                        : "Nothing in \(model.fileScope.title) matches. Try searching your whole home folder."
                ) {
                    if model.fileScope != .home {
                        Button("Search Home") { model.fileScope = .home }.buttonStyle(.or(.secondary, large: true))
                    }
                }
            }
        case .clipboard:
            if !model.query.isEmpty || model.clipboardFilter != .all {
                EmptyStateView(
                    kind: .clipboard, symbol: "line.3.horizontal.decrease", title: "No matching items",
                    detail: "Your saved history is still here. Try another search or show every type."
                ) {
                    if !model.query.isEmpty {
                        Button("Clear Search") {
                            model.query = ""
                            model.focusRequest += 1
                        }
                        .buttonStyle(.or(.secondary, large: true))
                    }
                    if model.clipboardFilter != .all {
                        Button("Show All Types") { model.clipboardFilter = .all }.buttonStyle(.or(.secondary, large: true))
                    }
                }
            } else {
                EmptyStateView(
                    kind: .clipboard, title: "Ready when you copy",
                    detail: "Copy text, an image or files in any app and they'll appear here. History stays on this Mac.")
            }
        case .snippets, .quicklinks, .notes:
            if model.query.isEmpty {
                EmptyStateView(kind: model.section.kind, title: "No \(model.section.itemNoun)s yet", detail: emptyDetail) {
                    Button {
                        model.createItem()
                    } label: {
                        HStack(spacing: 8) {
                            Text("New \(model.section.itemNoun.capitalized)")
                            KeyCaps(["⌘", "N"], size: .small, style: .onAccent)
                        }
                    }
                    .buttonStyle(.or(.primary, large: true))
                    .accessibilityHint(KeyShortcut(["⌘", "N"]).spoken)
                    .accessibilityIdentifier("library.create")
                }
            } else {
                noMatches
            }
        case .applications:
            if model.applications.isLoading {
                EmptyStateView(kind: .system, symbol: "square.grid.2x2", title: "Finding your apps…", detail: "OpenRay looks in your Applications folders.")
            } else {
                noMatches
            }
        case .provided(let scope):
            ProvidedScopeEmptyState(model: model, scope: scope)
        case .home where model.isQueryBlank:
            // Nothing pinned or used yet, so welcome rather than “No matches”.
            EmptyStateView(
                kind: .system, symbol: "star", title: "Type to search",
                detail: "Find apps, commands, snippets, notes and files. Press ⇧⌘F on any result to add it to Favorites here.")
        default:
            noMatches
        }
    }

    private var noMatches: some View {
        EmptyStateView(
            kind: model.section.kind, symbol: "magnifyingglass", title: "No matches for “\(model.query.truncatedForFeedback)”",
            detail: "Try a different name or keyword, or clear the search to see everything in \(model.section.title)."
        ) {
            Button("Clear Search") {
                model.query = ""
                model.focusRequest += 1
            }
            .buttonStyle(.or(.secondary, large: true))
        }
    }

    private var emptyDetail: String {
        switch model.section {
        case .snippets: "Save text you type often and paste it with a keyword."
        case .quicklinks: "Open a website, a folder or a search with a short keyword."
        default: "Jot something down. Notes save as you type and stay on this Mac."
        }
    }

    private var examples: some View {
        ForEach(["(120 + 45) * 0.2", "10 km in mi", "72 f in c"], id: \.self) { example in
            ExampleChip(text: example) {
                model.query = example
                model.focusRequest += 1
            }
        }
    }
}

/// Turning clipboard history on: what's excluded first, choices up front,
/// and a warning before the macOS prompt.
struct ClipboardOptInView: View {
    @Bindable var model: LauncherModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    KindTile(kind: .clipboard, size: 40).padding(.bottom, 16)
                    Text("Find anything you've copied").font(OR.Font.display).tracking(-0.4)
                        .foregroundStyle(OR.Color.text)
                    Text("OpenRay keeps what you copy on this Mac so you can search it and paste it again. Nothing is captured until you turn it on.")
                        .font(OR.Font.body).lineSpacing(3).foregroundStyle(OR.Color.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    Text("Never saved").font(OR.Font.calloutEmphasis).foregroundStyle(OR.Color.text2).padding(.top, 18)
                    VStack(alignment: .leading, spacing: 7) {
                        excluded("Passwords from known password managers")
                        excluded("Content apps mark as confidential")
                        excluded("Anything copied during Secure Input")
                        excluded("Apps you exclude")
                    }
                    .padding(.top, 8)
                    Text("Other sensitive text you copy can still be saved. Pause capture from the action bar whenever you need to.")
                        .font(OR.Font.callout).lineSpacing(2).foregroundStyle(OR.Color.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        // Always captured: drawn as an on switch (a disabled one looks broken), but it's
                        // not a control, so it takes no focus and VoiceOver reads it as a fact.
                        HStack(spacing: 10) {
                            optionLabel("text.alignleft", "Text and links", detail: "always on")
                            Spacer(minLength: 0)
                            SwitchKnob(isOn: true)
                        }
                        .padding(.horizontal, 14).frame(height: 44)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Text and links are always saved")
                        Hairline()
                        optionRow("photo", "Images", detail: "up to 10 MB each", isOn: $model.clipboardOptIn.images)
                        Hairline()
                        optionRow("folder", "Files", detail: "references only", isOn: $model.clipboardOptIn.files)
                    }
                    .background(OR.Color.fill1, in: .rect(cornerRadius: OR.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: OR.Radius.card, style: .continuous).strokeBorder(OR.Color.separator)
                    }
                    HStack {
                        Text("Keep for").foregroundStyle(OR.Color.text)
                        Spacer()
                        SegmentedPicker(
                            options: [(1, "1 day"), (7, "7 days"), (30, "30 days")], selection: $model.clipboardOptIn.days,
                            accessibilityLabel: "Keep for")
                    }
                    .padding(.horizontal, 2).padding(.top, 4)
                    HStack {
                        Text("Keep up to").foregroundStyle(OR.Color.text)
                        Spacer()
                        DropdownMenu(
                            options: [50, 100, 250, 500].map { ($0, "\($0) entries") }, selection: $model.clipboardOptIn.limit,
                            accessibilityLabel: "Keep up to")
                    }
                    .padding(.horizontal, 2)
                    Spacer(minLength: 0)
                    InlineNotice(
                        .info, symbol: "info.circle", title: "macOS will ask next.",
                        detail: "Choose Always Allow to keep capturing in the background.", emphasis: "Always Allow")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(OR.Font.body)
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
            .frame(maxHeight: .infinity, alignment: .top)

            ActionBar(
                feedback: model.feedback ?? model.store.errorMessage.map { .error($0) }, confirmation: nil,
                context: {
                    Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                    Text("Stored in Application Support/OpenRay")
                },
                actions: {
                    ActionBarButton(title: "Not Now", keys: ["esc"], style: .ghost) { model.goBack() }
                    ActionBarButton(title: "Turn On", keys: ["↩"], style: .accent) { model.enableClipboardHistory() }
                })
        }
    }

    private func excluded(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(OR.Color.success)
            Text(text).font(.system(size: 12.5)).foregroundStyle(OR.Color.text)
        }
        .accessibilityElement(children: .combine)
    }

    private func optionRow(_ symbol: String, _ title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { optionLabel(symbol, title, detail: detail) }
            .toggleStyle(.orSwitch)
            .padding(.horizontal, 14).frame(height: 44)
    }

    private func optionLabel(_ symbol: String, _ title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(OR.Color.text2).frame(width: 18)
            Text("\(Text(title).foregroundStyle(OR.Color.text))\(Text(detail.map { " · \($0)" } ?? "").font(OR.Font.callout).foregroundStyle(OR.Color.text2))")
        }
    }
}
