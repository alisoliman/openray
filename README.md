# OpenRay

A native macOS launcher for apps, files, clipboard history, window management, and on-device AI. OpenRay lives in your menu bar and opens with **⌥ Space**.

Built with SwiftUI and AppKit. No account, API key, analytics, or third-party package dependencies.

[Download the latest release](https://github.com/alisoliman/openray/releases/latest) · [Report an issue](https://github.com/alisoliman/openray/issues) · [Contribute](CONTRIBUTING.md)

## Install

1. Download **OpenRay-macos-arm64.dmg** from the [latest release](https://github.com/alisoliman/openray/releases/latest).
2. Open the disk image and copy **OpenRay.app** to **Applications**.
3. Launch OpenRay and press **⌥ Space** to show or hide the launcher.

OpenRay requires **macOS 26 or later on an Apple silicon Mac (M1 or later)**. Intel Macs are not supported. A ZIP archive and SHA-256 checksums are also available on the release page.

Updates are manual: quit OpenRay, download the new release, and replace the app in Applications. Your local library is retained. There is no automatic updater.

AI features additionally require Apple Intelligence enabled, a supported language, and the on-device model downloaded. The other features work without AI. Check model availability in **Settings → Apple Intelligence**. Choose **OpenRay Help** from the menu bar for the built-in guide.

## Features

| Feature | What you can do |
| --- | --- |
| App launcher | Find and open apps with fuzzy search, icons, favorites, and recents. |
| Command bindings | Assign unique aliases and global shortcuts to frequently used commands in Settings. |
| File search | Search filenames in your home folder with Spotlight; open, reveal in Finder, copy paths, and save favorites. |
| Calculator | Evaluate arithmetic, percentages, powers, and scientific functions; convert length, mass, duration, temperature, storage, and volume. |
| Clipboard history | Keep text, images, and grouped file references with previews, filters, exclusions, and configurable retention. Capture is opt-in. |
| Snippets | Save reusable text with `{date}` and `{time}` placeholders; optionally expand keywords as you type in other apps. |
| Quicklinks | Open named URLs, files, and folders, or search the web with `{query}` templates and keywords. |
| Notes | Create, edit, search, and copy local notes. Save an AI response as a note when you want to keep it. |
| Window management | Arrange windows in halves or quarters, maximize, center, move to the next display, or restore their original frame. |
| AI | Chat, summarize, rewrite, proofread, shorten text, and extract action items using Apple's on-device Foundation Models framework. |

Try `6 * 7`, `200 * 15%`, `sqrt(144)`, `10 km in mi`, `72 f in c`, or `web swift concurrency`. Calculator `%` divides the preceding value by 100; trigonometric functions use radians. Storage conversions distinguish decimal MB/GB from binary MiB/GiB.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| **⌥ Space** | Show or hide OpenRay; configurable in Settings. |
| **↑ / ↓** | Select a result. |
| **Return** | Open, run, or copy the selected result. |
| **⌘K** | Show actions for the selected result. |
| **⌘Return** | Paste a supported result into the previously active app; send a message in AI. |
| **⌘N** | Create an item in Snippets, Quicklinks, or Notes; start a new AI conversation. |
| **⌘S** | Save an editor. |
| **⌘,** | Open Settings. |
| **Escape** | Close actions, go back, clear the search, or dismiss the launcher. |

In AI, **Return** inserts a newline. Use **Stop** to cancel a response.

### Command aliases and hotkeys

In **Settings → Command aliases & hotkeys**, choose **Edit…** beside a command to assign an alias, record a shortcut, or remove its binding. Bindings are available for Applications, Files, Clipboard History, Snippets, Quicklinks, Notes, Calculator, Window Management, Ask AI, Settings, and these window commands: Left Half, Right Half, Maximize, Center, and Restore Window. They are saved in your local library. Individual apps, snippets, quicklinks, and clipboard entries do not have command bindings.

Type an exact alias in any search section to bring its command to the top. Matching ignores case and surrounding whitespace. Aliases must be a single token of up to 32 characters and unique across command aliases, quicklink keywords, and snippet keywords.

Shortcuts combine a physical key with Command, Control, Option, and/or Shift; labels follow the keyboard layout. Modifier-only gestures, separate left/right modifiers, and all-four-modifier Hyper shortcuts are unsupported. Reserved macOS shortcuts are blocked; other detected conflicts require **Save Anyway**. A saved shortcut may remain inactive if it conflicts, with an explanation in Settings. The launcher shortcut has priority, followed by command bindings in saved order. Recording temporarily pauses OpenRay's shortcuts, and saving or removing a binding updates them immediately. **Menu bar → Open OpenRay** remains available if a shortcut fails. Window commands still require Accessibility and an accessible focused window.

## Permissions and privacy

**Clipboard capture and automatic snippet expansion are off by default.** Enable them in Settings when needed.

- **Accessibility** enables window layouts, direct paste, selected-text import, and snippet expansion. OpenRay requests it only when you choose **Enable…** in Settings.
- **Clipboard access** is controlled separately by macOS. After enabling history, allow access when prompted; choose **Always Allow** for uninterrupted capture. Image and file capture have separate toggles.
- **File search** depends on Spotlight indexing and macOS folder permissions. It excludes hidden paths, `~/Library`, app contents, `node_modules`, and DerivedData.

Clipboard history skips confidential/transient content markers, known password managers, excluded apps, and Secure Input. Unmarked sensitive content can still be captured. App exclusions use the foreground app observed during polling, so rapid app switching can affect attribution.

History defaults to **7 days and 100 entries**, with a configurable maximum of 500 entries and a 64 MB content budget. Images are stored as PNGs up to 10 MB each. Copied files are references to the originals; clearing history never deletes those originals. Pausing capture keeps saved history available.

AI runs on-device with no cloud fallback. Clipboard and selected text enter a conversation only through their explicit import buttons. Conversations are not saved automatically; **Save as Note** saves the chosen response. AI input is limited to 6,000 characters.

### Local data

Preferences, command bindings, favorites, recents, snippets, quicklinks, notes, and enabled clipboard history are stored in:

```text
~/Library/Application Support/OpenRay/library.json
~/Library/Application Support/OpenRay/ClipboardImages/
```

The library uses local JSON and PNG files with owner-only permissions and atomic saves. It is **not encrypted by OpenRay**. Back up both paths together. Invalid or newer-format libraries are preserved and opened read-only with an error. Deletions have no in-app undo.

OpenRay is not App Sandbox-enabled because it integrates with other applications and the global clipboard. macOS privacy permissions still apply. See the [privacy notice](docs/privacy-policy.md) for details, including how web quicklinks open external services, and the [support guide](docs/support.md) for backup and uninstall instructions.

## Build from source

Use an Apple silicon Mac running macOS 26 or later and Xcode with the macOS 26 SDK or later. Development and CI use **Xcode 26.6 / Swift 6.3.3**, in Swift 6 language mode with strict concurrency. Both build configurations target `arm64`.

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

The default suite uses isolated temporary libraries and private test pasteboards. It covers search and alias ranking, command-binding validation and migration, shortcut registration and failure recovery, calculations, persistence, clipboard media and privacy rules, snippets, window geometry, and AI state handling. In-process shortcut routing is tested, but global delivery, live window manipulation, and text expansion require interactive verification with the relevant permissions.

[CI](.github/workflows/ci.yml) also checks workflow and release tooling and packages an installer preview. See [CONTRIBUTING.md](CONTRIBUTING.md) for formatting and contribution checks.

<details>
<summary>Manual UI and clipboard checks</summary>

For manual testing without saving library changes or using the system clipboard, launch the built executable in isolation:

```sh
DerivedData/Build/Products/Release/OpenRay.app/Contents/MacOS/OpenRay \
  --in-memory-library --verification-pasteboard OpenRayVerification.Manual
```

This mode disables cross-app paste, global shortcuts, snippet expansion, and login-item changes. Check that typing `6 * 7` immediately after launch shows `42`, and that search accepts typing immediately after closing an editor or going Back.

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
- **An installed app is missing:** use **Settings → Refresh Apps**.
- **File results are missing:** check Spotlight indexing and folder access. Search is limited to filenames in your home folder and applies the exclusions above.
- **Accessibility appears enabled but features do not work:** quit and reopen the same build, then choose **Settings → Refresh Status**. For a rebuilt ad-hoc app, remove only OpenRay's entry from the macOS Accessibility list and add the current `.app` again.
- **AI is unavailable:** check the status in **Settings → Apple Intelligence**, enable Apple Intelligence, and allow its model download to finish.

Choose **OpenRay Help** from the menu bar, or consult the [support guide](docs/support.md) for more help. Report reproducible problems through [GitHub Issues](https://github.com/alisoliman/openray/issues); issues are public, so remove private clipboard content, personal paths, and credentials before posting.

OpenRay currently has no extension marketplace, cloud sync, third-party AI providers, live currency rates, or natural-language date calculations. AI does not search the web or provide live facts.
