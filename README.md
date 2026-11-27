# OpenRay

A native macOS launcher for apps, files, clipboard history, window management, and on-device AI. OpenRay lives in your menu bar and opens with **⌥ Space**.

Built with SwiftUI and AppKit. No account, API key, analytics, or third-party package dependencies.

[Download the latest release](https://github.com/alisoliman/openray/releases/latest) · [Report an issue](https://github.com/alisoliman/openray/issues) · [Contribute](CONTRIBUTING.md)

## Install

1. Download **OpenRay-macos-arm64.dmg** from the [latest release](https://github.com/alisoliman/openray/releases/latest).
2. Open the disk image and copy **OpenRay.app** to **Applications**.
3. Launch OpenRay and press **⌥ Space** to show or hide the launcher.

OpenRay requires **macOS 27 or later on an Apple silicon Mac (M1 or later)**. Intel Macs are not supported. A ZIP archive and SHA-256 checksums are also available on the release page.

Updates are manual: quit OpenRay, download the new release, and replace the app in Applications. Your local library is retained. There is no automatic updater.

AI features additionally require Apple Intelligence enabled, a supported language, and the on-device model downloaded. The other features work without AI. Check model availability in **Settings → Apple Intelligence**. Choose **OpenRay Help** from the menu bar for the built-in guide.

## Features

| Feature | What you can do |
| --- | --- |
| App launcher | Find and open apps with fuzzy search and icons. Home shows up to eight favorites, opened with ⌘1–⌘8, and your four most recent items. |
| Command bindings | Assign unique aliases and global shortcuts to frequently used commands, edited in place in **Settings → Shortcuts**. |
| File search | Search filenames with Spotlight in your home folder or a chosen folder, with Quick Look previews; open, reveal in Finder, copy paths, paste into the previous app, and save favorites. |
| Calculator | Evaluate arithmetic, percentages, powers, and scientific functions; convert length, mass, duration, temperature, storage, and volume. |
| Clipboard history | Keep text, links, images, and grouped file references, grouped by day with previews, type filters, pinning, exclusions, and configurable retention. Capture is opt-in. |
| Snippets | Save reusable text with `{date}` and `{time}` placeholders in an inline editor with a live preview; optionally expand keywords as you type in other apps, per snippet. |
| Quicklinks | Open named URLs, files, and folders, or search with `{query}` templates: type a keyword and a space, then the search term. |
| Notes | Write local notes that save as you type. Save an AI response as a note when you want to keep it. |
| Pomodoro | Run a focus timer with short and long breaks, and track completed sessions against a daily goal. |
| Caffeinate | Keep your Mac and display awake indefinitely or for a chosen time, with a cup in the menu bar while it's on. |
| Window management | Arrange windows in halves or quarters, maximize, center, move to the next display, or restore their original frame. |
| AI | Chat, summarize, rewrite, proofread, shorten text, and extract action items using Apple's on-device Foundation Models framework. Writing commands pick up the text selected in the app you came from and show what changed. |

Try `6 * 7`, `200 * 15%`, `sqrt(144)`, `10 km in mi`, `72 f in c`, or `web swift concurrency`. Calculator `%` divides the preceding value by 100; trigonometric functions use radians. Storage conversions distinguish decimal MB/GB from binary MiB/GiB.

## Raycast-style commands and workflows

OpenRay follows Raycast's public features, workflows and keyboard model where they fit a native, offline launcher. Every AI feature runs on Apple Intelligence instead of a cloud model. Nothing here was taken from Raycast's app; the work is based on its public manual and its MIT-licensed extension and script repositories.

- **Commands everywhere.** Every command can take an alias and a global shortcut, including modifier-only gestures, double taps, one-sided modifiers, F13–F20 and an opt-in Hyper key. Commands with arguments get up to three inline fields. **⌘K** lists every action for the selection, in sections and submenus. Fallbacks are configurable, and ranking learns from your picks. **Settings → Commands** lists every command with its switch, alias, shortcut and preferences.
- **Clipboard, snippets and quicklinks.** Dynamic placeholders such as `{clipboard offset=1}`, `{selection}`, `{argument name="…"}`, dates with offsets and formats, `{uuid}` and `{cursor}`. Quicklinks open any URL scheme, take named arguments and can choose the app that opens them. Rich-text clipboard entries offer Paste As, and images get on-device text recognition. Raycast's JSON snippet and quicklink exports and macOS Text Replacements can be imported.
- **Calculator, emoji and translation.** Dates and durations, time zones, more units, percentages, number bases and history. Currency conversion uses European Central Bank rates only after you turn it on; it's the only network request OpenRay makes. An emoji and symbol grid, and on-device translation.
- **Files, screenshots and apps.** Path browsing, content search, scopes and ignore rules, file actions, a screenshot search with recognized text, Hide, Quit and Force Quit, Auto Quit and a reviewed Uninstall.
- **System and windows.** About 33 system commands, including audio devices, and about 44 window commands with gaps, cycling and saved layouts. Switch Windows, Search Menu Bar Items and a HUD for commands without a view.
- **Notes, calendar, Focus and Pomodoro.** A floating Markdown notes window, My Schedule with join links, Focus sessions that hide distracting apps, a Pomodoro timer and menu bar items for them.
- **Scripts and data.** Script Commands that read Raycast's public `@raycast.*` metadata, `openray://` deeplinks that always confirm risky commands, encrypted archive export and import, and scheduled backups to a folder you choose.
- **AI.** An AI Chat window with saved chats, your own AI Commands and agents, and @-mentions for your library, files, calendar, windows and system. Every write or action a tool takes asks for approval first.

Irreversible commands (Empty Trash, Shut Down, Restart, Log Out, Quit All, Quit Others, Force Quit) always confirm. On launcher rows, **Return** copies and **⌘Return** pastes into the app you came from; **Settings → General → Return on clipboard items, snippets and results** switches them, as Raycast does.

### Rewrite text where you are working

1. Select text in another app and run **Improve Writing** or another writing command, from **⌥ Space**, an alias, a hotkey or a favorite. It runs at once on the selection, and the result streams in under the command's name. Apps that don't share their selection over Accessibility are read by copying it, with your clipboard put back exactly; with nothing selected, OpenRay says so and offers the clipboard or typing.
2. Type a follow-up such as “Make it warmer” and press **Return** to refine the result. Each follow-up carries the original passage, the current result and your earlier requests.
3. With the field empty, press **Return** to paste the result over your selection: OpenRay closes, brings the app forward and, if the same text field is still focused and Secure Input is off, pastes, then puts your previous clipboard back and confirms with a short message such as **Improved**. If it can't paste, the result stays on the clipboard to paste with **⌘V**.

**⌘Return** copies the result instead and **⌥Return** pastes it with its formatting. **⌘R** regenerates it with other wording and **⇧⌘R** more freely. **⌘K** has **Show Original** and **Show Changes**; Fix Spelling & Grammar marks its changes as it opens (**Settings → Apple Intelligence → Writing commands**). Each new selection starts a new run, and **⌘[** and **⌘]** go back and forth between runs, so nothing is lost; reopening OpenRay soon after returns to the last result. **⌘J** continues a result in the AI Chat window. A stopped or failed run is never pasted.

**Quick Fix** runs Fix Spelling & Grammar (or the command you choose) in place, with no window, on the selection or, with **Prefer selection** off or nothing selected, the whole text field. It and AI Commands set to **Replace Selection** replace text only after checking it's exactly as it was; otherwise the result is copied.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| **⌥ Space** | Show or hide OpenRay; configurable in Settings. |
| **↑ / ↓**, **← / →** | Select a result; arrows move in two dimensions in the favorites strip and the windows grid. |
| **Return** | Open, run, or copy the selected result. The action bar always names what Return does. In AI: send, or with an empty field paste a finished writing result back into its app. |
| **⌘Return** | Send the result into the app you came from, such as **Paste to Mail**. On a writing result: copy it. In chat: add a new line, as **⇧Return** does. |
| **Tab** | Enter the selected command's scope, start a quicklink's search term, or ask AI with the current search. |
| **Delete** on an empty field | Leave the current scope or quicklink search term. |
| **⌘K** | Search every action for the selection; each shows its own shortcut. |
| **⌘/** | Show the shortcuts that work where you are. |
| **⌘1–⌘8** | Open a favorite. |
| **⌘N** | Create an item in Snippets, Quicklinks, or Notes; start a new AI conversation. |
| **⌘S** | Save an editor. |
| **⌘,** | Open Settings. |
| **Escape** | Close exactly one layer: a confirmation, actions, an editor, AI, a scope, the search, then the launcher. |
| **⌘[** | Go back one step, even when Escape is set to close the window. |

In AI chat, **Return** sends and **⇧Return** or **⌘Return** adds a new line. On a writing result, the keys follow Raycast: **Return** pastes it (or copies it, with **Settings → Apple Intelligence → Writing commands → Primary action** set to **Copy Response**), **⌘Return** does the other, **⌥Return** pastes it formatted, **⌘R** and **⇧⌘R** regenerate it, **⌘J** continues it in chat, **⌘N** starts a new one and **⌘[** / **⌘]** move between runs. Use **Stop** or **⌘.** to cancel a response; a stopped or partial result is never used by default.

### Command aliases and hotkeys

In **Settings → Shortcuts** and **Settings → Commands**, type an alias or record a shortcut directly in a command's row; clear a shortcut with its **×** button. Every command can have one, including Pomodoro, Start Pomodoro, Caffeinate, Start Caffeinate, Stop Caffeinate and Toggle Caffeinate, and so can individual apps, quicklinks and snippets. In the launcher, select a row and choose **Assign Alias or Shortcut…** from **⌘K** to jump to its row. Bindings are saved in your local library. Clipboard entries don't take bindings.

Type an exact alias in any search section to bring its command to the top. Matching ignores case and surrounding whitespace. Aliases must be a single token of up to 32 characters and unique across command aliases, quicklink keywords, and snippet keywords.

Shortcuts combine a physical key with Command, Control, Option, and/or Shift; labels follow the keyboard layout. A shortcut can also be a modifier-only gesture, a double tap, a left- or right-side modifier, F13–F20 alone, or a key with all four modifiers (the opt-in Hyper key in **Settings → Keyboard**). Reserved macOS shortcuts are blocked; other detected conflicts are explained on the row and require **Keep Anyway**. A saved shortcut may remain inactive if it conflicts, with an explanation in Settings. The launcher shortcut has priority, followed by command bindings in saved order. Recording temporarily pauses OpenRay's shortcuts, and saving or removing a binding updates them immediately. **Menu bar → Open OpenRay** remains available if a shortcut fails. Window commands still require Accessibility and an accessible focused window.

## Pomodoro

Search **Start Pomodoro** to start or resume the current timer phase, or **Pomodoro** to open the timer: start, pause, skip a break or reset from its list or **⌘K**, with today's progress and recent sessions beside it. A new cycle begins with focus. Both commands support aliases and global shortcuts. While a phase runs or a break is ready, the menu bar shows the countdown and controls; OpenRay's own menu can start a timer. Closing the launcher leaves the timer running.

Pomodoro and Focus are separate. Pomodoro paces your work and counts sessions; Focus hides distracting apps for a session. You can run both at once.

The default cycle uses a **25-minute focus**, a **5-minute short break**, and a **15-minute long break after every four completed focus sessions**, with a daily goal of **eight sessions**. Change these in **Settings → Pomodoro**: focus 1–180 minutes, short break 1–60 minutes, long break 1–120 minutes, long-break interval 1–12 sessions, and daily goal 1–24 sessions. You can also enable automatic break starts and turn the completion sound on or off. Sound is on and automatic break starts are off by default. Duration changes apply to the next phase; they preserve the remaining time of an active or paused phase.

Pause and resume as needed, skip a break, or reset the cycle. Each focus session starts manually. Only completed focus sessions count toward today's sessions and focus minutes; resetting an unfinished session or skipping a break adds no credit. Completed focus sessions are saved locally, with the latest 20 shown in the timer.

Timer state and progress are saved with your library. A running timer keeps its deadline across sleep or relaunch; an overdue phase is completed when OpenRay next checks it. An automatic break begins at that check, and OpenRay does not create a series of unattended focus sessions. Completion sounds play only while the app is running.

## Caffeinate

Search **Caffeinate** for its status and durations, **Start Caffeinate** to keep your Mac awake indefinitely, **Stop Caffeinate** to stop, or **Toggle Caffeinate** to switch it on or off. Start, Stop, and Toggle act immediately and close the launcher when successful. All four commands support aliases and global shortcuts. The menu bar shows a cup while it's on, with status and controls; OpenRay's own menu can start it.

In **Caffeinate**, choose **Indefinitely**, **10 or 30 minutes**, or **1, 2, 4, 8, or 12 hours**, or type a number of minutes from **1 to 1,440**. **Settings → Caffeinate** has the same choices, with a custom duration that's kept until you apply it. Choosing a length while it's on starts that length from now. Timed sessions stop automatically.

Caffeinate uses native macOS sleep assertions to prevent idle system and display sleep while OpenRay runs. Closing the launcher leaves it active; quitting OpenRay stops it. Sessions are not saved or resumed after relaunch. Caffeinate does not override closing a laptop lid or choosing Sleep manually.

## Permissions and privacy

**Clipboard capture and automatic snippet expansion are off by default.** Turn on clipboard history from its scope or in Settings; file references start off.

- **Accessibility** enables window layouts, direct paste, selected-text import, and snippet expansion. OpenRay requests it only when you choose **Enable…**. **Settings → Permissions** shows every permission with its live status.
- **Clipboard access** is controlled separately by macOS. After enabling history, allow access when prompted; choose **Always Allow** for uninterrupted capture. Image and file capture have separate toggles. Pause or resume capture from the menu bar; its icon shows an amber dot while capture is paused.
- **File search** depends on Spotlight indexing and macOS folder permissions. It excludes hidden paths, `~/Library`, app contents, `node_modules`, and DerivedData.

Clipboard history skips confidential/transient content markers, known password managers, excluded apps, and Secure Input. Unmarked sensitive content can still be captured. App exclusions use the foreground app observed during polling, so rapid app switching can affect attribution.

History defaults to **7 days and 100 entries**, with a configurable maximum of 500 entries and a 64 MB content budget. Images are stored as PNGs up to 10 MB each. Copied files are references to the originals; clearing history never deletes those originals. Pausing capture keeps saved history available. Pinned entries are kept past the retention period and entry limit, and claim the 64 MB budget before unpinned entries.

AI runs on-device with no cloud fallback. Clipboard and selected text reach the model only when you attach them, or when you start a writing command, which uses the text selected in the app you came from. That selection and where it came from stay in memory for the writing task, so the result can replace it after OpenRay checks it hasn't changed. Launcher conversations are not saved automatically; **Save as Note** saves the chosen response, and the AI Chat window saves its chats on this Mac. AI input is limited to 6,000 characters.

### Local data

Preferences, command bindings, favorites, recents, snippets, quicklinks, notes, Pomodoro configuration, timer state and completed-session history, and enabled clipboard history are stored in:

```text
~/Library/Application Support/OpenRay/library.json
~/Library/Application Support/OpenRay/ClipboardImages/
```

The library uses local JSON and PNG files with owner-only permissions and atomic saves. It is **not encrypted by OpenRay**. Back up both paths together. Invalid or newer-format libraries are preserved and opened read-only with an error. Deletions have no in-app undo.

OpenRay is not App Sandbox-enabled because it integrates with other applications and the global clipboard. macOS privacy permissions still apply. See the [privacy notice](docs/privacy-policy.md) for details, including how web quicklinks open external services, and the [support guide](docs/support.md) for backup and uninstall instructions.

## Build from source

Use an Apple silicon Mac running macOS 27 or later and Xcode with the macOS 27 SDK or later. Development and CI use **Xcode 27.0 / Swift 6.4** on macOS 27, in Swift 6 language mode with strict concurrency. Both build configurations target `arm64`.

```sh
git clone https://github.com/alisoliman/openray.git
cd openray
```

Open `OpenRay.xcodeproj`, select the **OpenRay** scheme, and run it. The checked-in project is the source of truth for build settings and includes source folders automatically; no project generator or dependency installation is needed.

To build a Release app locally with ad-hoc signing:

```sh
xcodebuild -project OpenRay.xcodeproj -scheme OpenRay \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
open DerivedData/Build/Products/Release/OpenRay.app
```

This command produces a local build. Distribution to other Macs requires Developer ID signing and notarization. Keep the app at a stable location before enabling launch at login or granting Accessibility.

### Verification

Run the automated suite:

```sh
./scripts/verify.sh
```

On a Mac with Apple Intelligence ready, include the actual model integration test:

```sh
./scripts/verify.sh --ai
```

The default suite uses isolated temporary libraries and private test pasteboards. It covers search and alias ranking, command-binding validation and migration, shortcut registration and failure recovery, calculations, persistence, clipboard media and privacy rules, snippets, Pomodoro navigation and shortcut routing, window geometry, and AI state handling. In-process shortcut routing is tested, but global delivery, live window manipulation, and text expansion require interactive verification with the relevant permissions.

[CI](.github/workflows/ci.yml) also checks workflow and release tooling and packages an installer preview. See [CONTRIBUTING.md](CONTRIBUTING.md) for formatting and contribution checks.

<details>
<summary>Manual UI and clipboard checks</summary>

For manual testing without saving library changes or using the system clipboard, launch the built executable in isolation:

```sh
DerivedData/Build/Products/Release/OpenRay.app/Contents/MacOS/OpenRay \
  --in-memory-library --verification-pasteboard OpenRayVerification.Manual
```

This mode disables cross-app paste, global shortcuts, snippet expansion, and login-item changes. Add `--first-run` to walk through the first-run guide, or `--open-settings <pane>` (for example `shortcuts` or `permissions`) to open a Settings pane at launch. Check that typing `6 * 7` immediately after launch shows `42`, and that search accepts typing immediately after closing an editor or going Back.

[scripts/ui-smoke.mjs](scripts/ui-smoke.mjs) provides helpers for these checks and image-copy verification in a Computer Use CUA session. Pass an app handle for the isolated build; the helpers are not a standalone test runner. CI checks their JavaScript syntax. When multiple builds are installed, select the exact `.app` path.

Use `scripts/clipboard-fixture.swift` to populate or inspect the private pasteboard. For example, enable clipboard capture and image capture in the isolated app, then run:

```sh
swift scripts/clipboard-fixture.swift OpenRayVerification.Manual \
  image OpenRay/Assets.xcassets/AppIcon.appiconset/icon_512.png
swift scripts/clipboard-fixture.swift OpenRayVerification.Manual describe
```

Open Clipboard History with an empty search, select the image, and press Return to verify it copies as an image. After quitting the isolated app, release the pasteboard:

```sh
swift scripts/clipboard-fixture.swift OpenRayVerification.Manual release
```

</details>

Regenerate the app icon assets with `swift scripts/generate-app-icon.swift`.

## Releases

Public releases require Developer ID Application signing and Apple notarization. The [release guide](docs/RELEASE.md) covers local packaging, credentials, artifact verification, and manual release checks. The [GitHub release pipeline guide](docs/GITHUB-RELEASES.md) covers CI previews, SemVer-tagged releases, draft preparation, signing configuration, and permanent download URLs. Stable releases update GitHub's Latest link; prereleases remain separate.

To build a local installer preview without distribution credentials:

```sh
./scripts/package-release.sh --preview
```

Packaging creates an Apple silicon app, ZIP, drag-to-Applications DMG, checksums, and verification logs under `.build/releases/`. Preview artifacts are labeled `local-preview` and use ad-hoc signing; they must not be published as production downloads. Follow the release guide for signed, notarized distribution.

## Troubleshooting

- **The launcher shortcut does not work:** another app may own **⌥ Space**. Open Settings from the menu bar and select another shortcut.
- **An installed app is missing:** use **Settings → General → Applications → Refresh**.
- **File results are missing:** check Spotlight indexing and folder access. Search is limited to filenames in your home folder and applies the exclusions above.
- **Accessibility appears enabled but features do not work:** quit and reopen the same build, then reopen **Settings → Permissions**; status refreshes when the window becomes active. For a rebuilt ad-hoc app, remove only OpenRay's entry from the macOS Accessibility list and add the current `.app` again.
- **AI is unavailable:** check the status in **Settings → Apple Intelligence**, enable Apple Intelligence, and allow its model download to finish.

Choose **OpenRay Help** from the menu bar, or consult the [support guide](docs/support.md) for more help. Report reproducible problems through [GitHub Issues](https://github.com/alisoliman/openray/issues); issues are public, so remove private clipboard content, personal paths, and credentials before posting.

OpenRay currently has no extension marketplace, cloud sync, third-party AI providers, live currency rates, or natural-language date calculations. AI does not search the web or provide live facts.
