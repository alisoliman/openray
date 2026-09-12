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
                        Spelling & Grammar. The feature bar opens All, Apps, Files, Clipboard, \
                        Notes, Pomodoro, and AI. More opens Snippets, Quicklinks, Windows, and Calculator. \
                        Files uses Spotlight in your home folder; hidden files, \
                        Library, and generated development folders are excluded.
                        """)
                    Text(
                        """
                        In All, type a question or passage and press Tab to carry it into the AI \
                        workspace as an editable draft. Choose a tool, then press Return when \
                        you are ready to send it. If Ask already has an unsent draft, it is \
                        preserved; go Back to recover the new search text.
                        """)
                }

                section("Keyboard shortcuts", symbol: "keyboard") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        shortcut("↑ / ↓", "Select a result or an action")
                        shortcut(
                            "Return",
                            """
                            Open or copy the selected result; send an AI draft or accept a completed rewrite
                            """)
                        shortcut("⌘K", "Open or close actions for the selected result or current AI tool")
                        shortcut("Tab", "From All, open AI with your search text; in AI, move to the next control")
                        shortcut("Shift-Tab", "In AI, move to the previous control")
                        shortcut("⌘1–⌘6", "In search: All, Apps, Files, Clipboard, Notes, AI")
                        shortcut("⌘1–⌘6 in AI", "Ask, Rewrite, Summarize, Proofread, Shorten, Actions")
                        shortcut(
                            "⌘Return",
                            """
                            Paste a clipboard item, snippet, calculation, or note into the \
                            previously active app; insert a new line in the AI composer
                            """)
                        shortcut(
                            "⌘N",
                            """
                            Create a note, snippet, or quicklink in its feature; start a new \
                            conversation in the current AI tool
                            """)
                        shortcut("⌘S", "Save the current editor")
                        shortcut("⌘,", "Open Settings")
                        shortcut("Escape", "Hide the launcher and keep your place; close an open actions menu first")
                        shortcut("⌘[", "Go back to the previous workspace")
                    }
                    Text(
                        """
                        Use Back or ⌘[ to navigate. Hiding with Escape, the launcher shortcut, or \
                        another app keeps your workspace for five minutes. After a longer pause, \
                        OpenRay opens All, while AI drafts, conversations, and unsaved library \
                        editors remain available. Native dialogs handle Escape first.
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

                section("Focus with Pomodoro", symbol: "timer") {
                    Text(
                        """
                        Search Start Pomodoro to start or resume the current phase, or Pomodoro \
                        to open the timer and see today's completed sessions, focus minutes, and \
                        recent history. A new cycle begins with focus. \
                        Both commands support aliases and global shortcuts. The menu bar shows the \
                        active countdown and timer controls. Closing the launcher leaves it running.
                        """)
                    Text(
                        """
                        Start with 25 minutes of focus, 5-minute short breaks, and a 15-minute long \
                        break after four completed sessions. Settings lets you change durations, \
                        the long-break interval, and the daily goal of eight sessions, and choose \
                        automatic break starts or a completion sound. Each focus session starts \
                        manually. Changed durations apply to the next phase.
                        """)
                    Text(
                        """
                        Pause and resume, skip a break, or reset the cycle. Only completed focus \
                        sessions count toward progress; reset preserves completed history. Timer \
                        state and history are saved locally. After sleep or relaunch, an overdue \
                        phase completes when OpenRay checks its saved deadline. An automatic break \
                        begins at that point. Sounds play only while OpenRay is running.
                        """)
                }

                section("Stay awake with Caffeinate", symbol: "cup.and.saucer") {
                    Text(
                        """
                        Search Caffeinate to open its controls and status, Start Caffeinate to \
                        keep your Mac awake indefinitely, Stop Caffeinate to stop, or Toggle \
                        Caffeinate to switch it on or off. Start, Stop, and Toggle act immediately \
                        and dismiss the launcher when successful. All four commands support aliases \
                        and global shortcuts. The menu bar shows a coffee icon while active, with \
                        status and controls.
                        """)
                    Text(
                        """
                        Choose Indefinitely, 10 or 30 minutes, 1, 2, 4, 8, or 12 hours, or a custom \
                        duration of 1–1,440 minutes, then press Start Caffeinate or Update Duration. \
                        Updating starts the chosen duration from now and replaces the current \
                        deadline. Timed sessions stop automatically.
                        """)
                    Text(
                        """
                        Caffeinate uses native macOS sleep assertions to prevent idle system and \
                        display sleep while OpenRay runs. Closing the launcher leaves it active; \
                        quitting OpenRay stops it. Sessions are not saved or resumed after \
                        relaunch. Closing a laptop lid or choosing Sleep manually still takes \
                        precedence.
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
                        Choose Ask for a conversation, or Rewrite, Summarize, Proofread, Shorten, \
                        or Actions for a writing task. Actions extracts action items. Click a tool \
                        or use ⌘1 through ⌘6 to jump directly to it. Tab and Shift-Tab move keyboard \
                        focus between controls.
                        """)
                    Text(
                        """
                        Select text in another app, open OpenRay, and choose Improve Writing or \
                        another writing command. With Accessibility enabled, the command uses \
                        your selection in an empty tool, or starts a new selection after a completed \
                        result with no unsent draft or error. Drafts, ongoing responses, and stopped \
                        or failed requests are kept; choose Use as new passage to replace that work. \
                        Hiding, reopening, or browsing tools preserves a previous result. Run the \
                        writing command again to begin another selection. Ask never imports a \
                        selection automatically.
                        """)
                    Text(
                        """
                        Return sends your draft. ⌘Return inserts a new line. After a writing \
                        response finishes, type a follow-up such as “Make it warmer” and press \
                        Return to refine the result. With an empty composer, Return accepts the \
                        latest completed result and replaces the original selection in its app. \
                        If that selection has changed, OpenRay keeps the result available to copy \
                        instead of replacing other text. Copy and Save as Note are also available.
                        """)
                    Text(
                        """
                        Stop ends a response and keeps its partial text; stop before changing \
                        tools. Each tool keeps its own draft and conversation while OpenRay is \
                        running. ⌘N starts fresh in the current tool. Input is limited to 6,000 \
                        characters. In a writing tool, Use Clipboard and Use Selected Text start \
                        work on a new source.
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
                        favorites, recent-use history, Pomodoro state and history, and enabled \
                        clipboard history are stored in \
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
                        A writing command can use the selection from the app where you opened \
                        OpenRay. Otherwise, clipboard and selected text enter AI when you choose \
                        their import buttons. AI drafts and chats stay in memory; Save as Note is the explicit way to store a \
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
