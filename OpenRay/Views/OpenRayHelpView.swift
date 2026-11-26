import SwiftUI

struct OpenRayHelpButton: View {
    let model: LauncherModel

    var body: some View {
        Button("OpenRay Help") { model.openHelp() }
            .keyboardShortcut("?", modifiers: .command)
    }
}

/// The full guide and privacy details. ⌘/ in the panel covers shortcuts in context.
struct OpenRayHelpView: View {
    static let windowID = "openray-help"
    let model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 16) {
                    ORMark(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenRay Help").font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                            .accessibilityAddTraits(.isHeader)
                        Text("Find, create and work from your keyboard.").font(.system(size: 15))
                            .foregroundStyle(OR.Color.text2)
                        Text("Version \(AppInformation.version) · Apple silicon · macOS 27+").font(OR.Font.callout)
                            .foregroundStyle(OR.Color.text2)
                    }
                }

                section("Start with search", kind: .command, symbol: "magnifyingglass") {
                    paragraph(
                        "Press \(model.store.database.preferences.hotKey.title) in any app to show or hide OpenRay. Type an app, a file, a command such as Snippets or a calculation. The top result is selected, and the action bar names what Return does.")
                    paragraph(
                        "Favorites open with ⌘1 to ⌘8. Commands such as Clipboard History are scopes: they appear as a token in the field. Press ⌫ on an empty field to leave a scope, or Esc to go back one step.")
                }

                section("Keyboard", kind: .command, symbol: "keyboard") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        shortcut(["↑", "↓"], "Move through results; ← → in grids")
                        shortcut(["↩"], "Copy or open the selection")
                        shortcut(["⌘", "↩"], "Send it into the app you came from (Paste to Mail)")
                        shortcut(["Tab"], "Enter the selected scope, start a quicklink search or ask AI")
                        shortcut(["⌘", "K"], "All actions for the selection, searchable")
                        shortcut(["⌘", "/"], "Shortcuts that work where you are")
                        shortcut(["⌘", "1–8"], "Open a favorite")
                        shortcut(["⌘", "N"], "New note, snippet or quicklink; new chat in AI")
                        shortcut(["⌘", "S"], "Save an editor")
                        shortcut(["⌘", ","], "Settings")
                        shortcut(["esc"], "Close the top layer: actions, editor, scope, then the search")
                        shortcut(["⌘", "["], "Go back one step, even when Esc is set to close the window")
                    }
                    paragraph(
                        "In AI the keys follow the conversation: Return sends, ⇧Return or ⌘Return adds a line, and Return on an empty field uses a finished writing result.")
                        .foregroundStyle(OR.Color.text2)
                }

                section("Make everyday work reusable", kind: .snippet, symbol: "curlybraces") {
                    item("Snippets", "Save text with a keyword such as ;sig. {date} and {time} fill in when you copy or paste. With Accessibility on, keywords can expand as you type; each snippet has its own switch.")
                    item("Quicklinks", "Save a website, a folder, or a search such as https://duckduckgo.com/?q={query}. Type its keyword and a space in Everything, then the search term. ⌘2 and onward send the same term elsewhere.")
                    item("Notes", "Notes save as you type. The first line becomes the title. Esc is Done.")
                    item("Clipboard", "Turn on history to search what you copy. Return copies an entry; ⌘↩ pastes it. Pin entries to keep them past the retention limit, and filter by type with ⌘P.")
                }

                section("Calculate and arrange windows", kind: .calculator, symbol: nil) {
                    paragraph(
                        "Try 6 * 7, 200 * 15%, sqrt(144), 10 km in mi, 72 f in c or 1 GiB in MiB. Return copies the value without the unit. Currency conversion isn't supported because OpenRay never fetches rates.")
                    paragraph(
                        "Window Management shows each layout as a picture. Layouts apply to the window you came from, named in the field. They need Accessibility.")
                }

                section("Focus with Pomodoro", kind: .command, symbol: "timer") {
                    paragraph(
                        "Search Start Pomodoro to start or resume the current phase, or Pomodoro to see the timer, today's sessions and focus minutes, and your recent sessions. Pause, skip a break or reset the cycle from the list or ⌘K. The menu bar shows the countdown while a phase runs; closing the launcher leaves it running.")
                    paragraph(
                        "The default rhythm is 25 minutes of focus, 5-minute breaks and a 15-minute break after four sessions, with a goal of eight a day. Settings → Pomodoro changes them, starts breaks automatically and turns the chime on or off. Only completed focus sessions count. Timer and history are saved in your library, and a phase that ended while OpenRay was closed completes when it next runs.")
                    paragraph(
                        "Pomodoro paces your work and counts sessions. Focus hides distracting apps for a session. They're separate, and you can run both at once.")
                }

                section("Keep your Mac awake", kind: .system, symbol: "cup.and.saucer") {
                    paragraph(
                        "Start Caffeinate keeps your Mac and its display awake until you stop it; Stop Caffeinate and Toggle Caffeinate act at once and close the launcher. Caffeinate lists 10 minutes to 12 hours, and typing a number keeps it awake for that many minutes (1–1,440). Choosing a new length starts it from now.")
                    paragraph(
                        "It uses a macOS power assertion while OpenRay runs. Quitting stops it, and sessions aren't resumed after a relaunch. Closing the lid or choosing Sleep still puts the Mac to sleep. A cup shows in the menu bar while it's on.")
                }

                section("Work with AI", kind: .ai, symbol: nil) {
                    paragraph(
                        "Press Tab on any search to ask AI. Writing commands such as Fix Spelling & Grammar pick up the text you selected in another app and show what changed. Press Return on the empty field to replace the selection in its app; OpenRay checks the selection is unchanged first, and copies the result instead if it isn't.")
                    paragraph(
                        "After a result, type a follow-up such as Make it warmer and press Return to refine it. Try Again (⌘R) repeats the last request with the context it had, and Use Result as New Passage in ⌘K starts over from the result.")
                    paragraph(
                        "In chat, Return sends and ⇧Return or ⌘Return adds a line. Attach the clipboard or your selection explicitly. Requests are limited to 6,000 characters.")
                    paragraph(
                        "AI runs on this Mac with Apple Intelligence and never falls back to the cloud. It needs an eligible Mac, Apple Intelligence turned on, a supported language and the model downloaded. Review what it writes; it can't browse for live information.")
                }

                section("Your data and permissions", kind: .permission, symbol: "lock.fill") {
                    paragraph(
                        "No account, analytics, ads or cloud sync. Your library, favorites, recent items, Pomodoro timer and sessions, and clipboard history are stored in ~/Library/Application Support/OpenRay, readable only by your account but not encrypted by OpenRay. Back up library.json and ClipboardImages together.")
                    paragraph(
                        "Clipboard history and keyword expansion start off. Known password managers, content marked confidential, anything copied during Secure Input and apps you exclude are never saved. Other sensitive text can be, so pause capture from the menu bar or the action bar when you need to.")
                    paragraph(
                        "Accessibility is only for window layouts, pasting into other apps, reading selected text and keyword expansion. Everything else works without it. Settings → Permissions shows each one with its status.")
                    paragraph(
                        "Opening a quicklink hands its URL to your browser, and search terms go to the site you chose. Deleting items or clearing history can't be undone in OpenRay.")
                }

                section("Help and feedback", kind: .about, symbol: "questionmark") {
                    paragraph(
                        "If a shortcut doesn't work, another app may use it. Choose a different one in Settings → Shortcuts, where conflicts are explained. Install OpenRay in Applications before turning on Open at Login or Accessibility.")
                    HStack(spacing: 18) {
                        Link("Read the guide", destination: AppInformation.documentationURL)
                        Link("Report an issue", destination: AppInformation.supportURL)
                    }
                    .font(OR.Font.bodyEmphasis)
                    Text("GitHub issues are public. Remove private text, clipboard contents and personal file paths from screenshots and logs.")
                        .font(OR.Font.callout).foregroundStyle(OR.Color.text2)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 36).padding(.top, 40).padding(.bottom, 36)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 600, minHeight: 440)
        .tint(OR.Color.accent)
        .appAppearance(model.store.database.preferences.appearance)
        .accessibilityIdentifier("help.guide")
    }

    private func section<Content: View>(
        _ title: String, kind: Kind, symbol: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                KindTile(kind: kind, symbol: symbol, size: 26)
                Text(title).font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.leading, 36)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).foregroundStyle(OR.Color.text).fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(OR.Font.headline)
            Text(detail).foregroundStyle(OR.Color.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcut(_ keys: [String], _ description: String) -> some View {
        GridRow(alignment: .center) {
            KeyCaps(keys).gridColumnAlignment(.trailing)
            Text(description).foregroundStyle(OR.Color.text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(KeyShortcut(keys).spoken): \(description)")
    }
}
