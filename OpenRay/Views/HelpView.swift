import SwiftUI

struct HelpView: View {
    @Bindable var model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("OpenRay", systemImage: "command.square.fill").font(.largeTitle.bold())
                    Text("Your keyboard-first launcher for Mac").font(.title3).foregroundStyle(.secondary)
                    Text("Version \(AppInformation.version)").font(.caption).foregroundStyle(.secondary)
                }

                helpSection("Get started") {
                    Text(
                        "Press \(model.store.database.preferences.hotKey.title) to open or dismiss the launcher. OpenRay stays in your menu bar. Choose another shortcut in Settings if that one is already in use."
                    )
                    Text(
                        "Search for an app, note, snippet, or command. Try “6 * 7”, “10 km in mi”, or “web swift concurrency”. Open Files to search Spotlight; macOS folder permissions and indexing still apply."
                    )
                }

                helpSection("Keyboard shortcuts") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                        shortcut("↑ / ↓", "Select a result")
                        shortcut("Return", "Open the selected result or copy its content")
                        shortcut("⌘K", "Open the selected result’s actions")
                        shortcut("⌘Return", "Paste a result into the previous app, with Accessibility enabled")
                        shortcut("⌘N / ⌘S", "Create a library item / save its editor")
                        shortcut("⌘,", "Open Settings")
                        shortcut("Escape", "Close a menu, go back, clear search, or dismiss")
                    }
                    Text(
                        "In AI, Return adds a newline and ⌘Return sends. Stop cancels a response. AI needs an eligible Apple silicon Mac with Apple Intelligence enabled and its model downloaded; other features work without it."
                    )
                }

                helpSection("Privacy & your data") {
                    Text(
                        "OpenRay has no account, analytics, ads, or cloud sync. Notes, snippets, quicklinks, preferences, favorites, recent-use history, and enabled clipboard history stay in your Mac’s local library."
                    )
                    Text(
                        "Clipboard capture and automatic snippet expansion are off by default. Capture skips confidential and transient clipboard markers, known password managers, excluded apps, and Secure Input. These safeguards cannot detect every secret. You can pause capture, change retention, or delete history in Settings."
                    )
                    Text(
                        "Clipboard images are stored locally as PNGs. Copied files are references to the originals. Library files are restricted to your user account but are not encrypted by OpenRay. Back up library.json and ClipboardImages together. Deleting library entries has no in-app undo."
                    )
                    Text(
                        "AI runs through Apple’s on-device Foundation Models framework, with no cloud fallback. Clipboard and selected text are included only when you use their import buttons. Chats stay in memory until you quit or start a new conversation; Save as Note explicitly saves a response. Review generated text for accuracy."
                    )
                    Text(
                        "Accessibility permission is optional and enables window layouts, direct paste, selected-text import, and snippet expansion. OpenRay does not save what you type for expansion. macOS separately controls background clipboard access."
                    )
                    Text(
                        "Opening a web quicklink, a help link, or a support link hands its URL to your browser. Search-template queries are sent to the service you choose, whose privacy practices apply."
                    )
                }

                helpSection("Help & feedback") {
                    Text(
                        "If a shortcut fails, choose another in Settings. If permissions change, reopen the same app build and use Refresh Status. Install OpenRay in Applications before enabling launch at login or granting Accessibility."
                    )
                    HStack(spacing: 20) {
                        Link("Read the guide", destination: AppInformation.documentationURL)
                        Link("Report an issue", destination: AppInformation.supportURL)
                    }
                    Text(
                        "GitHub issues are public. Include your OpenRay and macOS versions and steps to reproduce; remove private text, clipboard contents, and personal file paths from screenshots and logs."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .preferredColorScheme(model.store.database.preferences.appearance.colorScheme)
    }

    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func shortcut(_ keys: String, _ explanation: String) -> some View {
        GridRow {
            Text(keys).font(.body.monospaced()).fixedSize()
            Text(explanation)
        }
        .accessibilityElement(children: .combine)
    }
}
