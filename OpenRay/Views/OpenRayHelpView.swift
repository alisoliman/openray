import SwiftUI

struct OpenRayHelpButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("OpenRay Help") { openWindow(id: OpenRayHelpView.windowID) }
            .keyboardShortcut("?", modifiers: .command)
    }
}

struct OpenRayHelpView: View {
    static let windowID = "openray-help"
    let model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("OpenRay Help", systemImage: "command.square.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Find, create, and work from your keyboard.")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                    Text("Version \(AppInformation.version) · Apple silicon · macOS 26+")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                section("Start with search", symbol: "magnifyingglass") {
                    Text(
                        """
                        Press \(model.store.database.preferences.hotKey.title) from any app to \
                        show or hide OpenRay. You can change this shortcut in Settings if another \
                        app uses it.
                        """)
                    Text(
                        """
                        Search an app name, a filename, or a command such as Snippets or Fix \
                        Spelling & Grammar. Use the Apps, Files, and Ask AI buttons to go straight \
                        to a feature. Files uses Spotlight in your home folder; hidden files, \
                        Library, and generated development folders are excluded.
                        """)
                }

                section("Keyboard shortcuts", symbol: "keyboard") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        shortcut("↑ / ↓", "Select a result or an action")
                        shortcut(
                            "Return",
                            """
                            Open or copy the selected result; run a selected action
                            """)
                        shortcut("⌘K", "Open or close actions for the selected result")
                        shortcut(
                            "⌘Return",
                            """
                            Paste a clipboard item, snippet, calculation, or note into the \
                            previously active app
                            """)
                        shortcut(
                            "⌘N",
                            """
                            Create a note, snippet, or quicklink in its feature; start a new \
                            conversation in AI
                            """)
                        shortcut("⌘S", "Save the current editor")
                        shortcut("⌘,", "Open Settings")
                        shortcut(
                            "Escape",
                            """
                            Close actions or an editor, go back from a feature, clear the root \
                            search, then hide the launcher
                            """)
                    }
                    Text(
                        """
                        In a text editor, Escape belongs to the editor first. Use Back to leave \
                        Settings while editing exclusions.
                        """
                    )
                    .foregroundStyle(.secondary)
                }

                section("Command aliases and hotkeys", symbol: "command") {
                    Text(
                        """
                        In Settings, use Command aliases & hotkeys to assign an alias or global \
                        shortcut to the available commands. Type an alias in the launcher to find \
                        its command, or use a global shortcut while another app is active. Save \
                        changes in the command editor; shortcut conflicts appear in Settings.
                        """)
                }

                section("Make everyday work reusable", symbol: "square.stack.3d.up") {
                    paragraph(
                        "Notes",
                        """
                        Create local notes, find them by title or content, and reopen them to \
                        edit. Use actions to copy, favorite, or delete an item.
                        """)
                    paragraph(
                        "Snippets",
                        """
                        Save reusable text with an optional keyword such as ;email. {date} and \
                        {time} expand when copied or pasted. Cross-app keyword expansion is \
                        optional in Settings and requires Accessibility.
                        """)
                    paragraph(
                        "Quicklinks",
                        """
                        Save a website, an absolute file path, or a search template such as \
                        https://example.com/search?q={query}. Give it a keyword such as web, then \
                        type web swift concurrency in OpenRay. Query text is encoded safely for \
                        the URL.
                        """)
                    paragraph(
                        "Clipboard",
                        """
                        Enable capture to keep a local history of copied text, images, and file \
                        references. Use the content-type filter to narrow results. Return copies \
                        an entry; ⌘Return pastes into the previously active app when Accessibility \
                        is enabled. Pause capture in Settings without losing saved entries.
                        """)
                }

                section("Calculate and arrange windows", symbol: "equal.square") {
                    Text(
                        """
                        Try 6 * 7, 200 * 15%, sqrt(144), 10 km in mi, 72 f in c, or 1 GiB in MiB. \
                        Return copies the answer. Trigonometric functions use radians; storage \
                        conversions distinguish MB from MiB. Live currency conversions are not \
                        supported.
                        """)
                    Text(
                        """
                        Window commands act on the app that was active before OpenRay. Choose a \
                        half, quarter, maximize, center, or next display. Restore returns the \
                        window to its saved original frame. These commands require Accessibility.
                        """)
                }

                section("Write with Apple Intelligence", symbol: "sparkles") {
                    Text(
                        """
                        Ask AI for a conversation, or choose Summarize, Improve Writing, Fix \
                        Spelling & Grammar, Make Shorter, or Extract Action Items. Enter the \
                        source text for a writing command.
                        """)
                    Text(
                        """
                        Return inserts a new line. ⌘Return sends. Stop ends a response and keeps \
                        its partial text. Use Copy for the output, Save as Note to keep it, and \
                        New Chat to start fresh. Input is limited to 6,000 characters.
                        """)
                    Text(
                        """
                        AI runs on this Mac using Apple Intelligence, with no cloud fallback. It \
                        requires an eligible Apple silicon Mac, Apple Intelligence enabled, a supported \
                        language, and the model downloaded. Settings shows readiness. Review \
                        generated text; the model does not browse for live information.
                        """)
                }

                section("Your data and permissions", symbol: "hand.raised") {
                    Text(
                        """
                        No account, analytics, ads, or cloud sync. Notes, snippets, links, preferences, \
                        favorites, recent-use history, and enabled clipboard history are stored in \
                        ~/Library/Application Support/OpenRay. \
                        Reveal Library in Finder is available in Settings. The files are local and \
                        restricted to your user account but are not encrypted by OpenRay. Back up \
                        library.json and ClipboardImages together.
                        """)
                    Text(
                        """
                        Clipboard capture and keyword expansion are off initially. Clipboard \
                        permission is separate from Accessibility. Known password managers and \
                        confidential or transient clipboard content are excluded. Capture also \
                        pauses during Secure Input, but unmarked \
                        sensitive content can still be captured. Add app bundle identifiers to \
                        exclusions or pause capture when needed. Retention, entry count, and media \
                        limits are shown in Settings.
                        """)
                    Text(
                        """
                        Accessibility is used only for window layouts, direct paste, selected-text \
                        import, and optional keyword expansion. Other features work without it. \
                        OpenRay does not save what you type for expansion or change system \
                        permissions for you.
                        """)
                    Text(
                        """
                        Clipboard and selected text enter AI only when you choose their import \
                        buttons. Chats stay in memory; Save as Note is the explicit way to store a \
                        response. Deleting library items or clearing history cannot be undone in \
                        OpenRay. Clearing clipboard history does not alter the current system \
                        clipboard or delete original copied files.
                        """)
                    Text(
                        """
                        Clipboard images are stored locally as PNGs. Copied files are references \
                        to the originals. Opening a quicklink, help link, or support link hands \
                        its URL to your browser. Search-template queries are sent to the service \
                        you choose, whose privacy practices apply.
                        """)
                }

                section("Help and feedback", symbol: "questionmark.circle") {
                    Text(
                        """
                        If a shortcut fails, choose another in Settings. If permissions change, \
                        reopen the same app build and use Refresh Status. Install OpenRay in \
                        Applications before enabling launch at login or granting Accessibility.
                        """)
                    HStack(spacing: 20) {
                        Link("Read the guide", destination: AppInformation.documentationURL)
                        Link("Report an issue", destination: AppInformation.supportURL)
                    }
                    Text(
                        """
                        GitHub issues are public. Include your OpenRay and macOS versions and \
                        steps to reproduce; remove private text, clipboard contents, and personal \
                        file paths from screenshots and logs.
                        """
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 600, minHeight: 440)
        .tint(RayStyle.accent)
        .accessibilityIdentifier("help.guide")
    }

    private func section<Content: View>(
        _ title: String, symbol: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func paragraph(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(detail)
        }
    }

    private func shortcut(_ keys: String, _ description: String) -> some View {
        GridRow(alignment: .top) {
            Text(keys).font(.system(size: 13, weight: .semibold, design: .monospaced))
                .fixedSize()
            Text(description).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
