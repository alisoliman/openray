# OpenRay

A native, keyboard-first macOS launcher inspired by [Raycast’s core features](https://manual.raycast.com/quickstart), with private AI powered by Apple Intelligence. Built with SwiftUI, AppKit where system integration requires it, and Swift 6 strict concurrency. No third-party package dependencies.

## Requirements

- macOS 26.0 or later.
- Xcode 26.6 / Swift 6.3.3 or later. The project uses Swift 6 language mode (`SWIFT_VERSION = 6.0`); the installed Xcode supplies the compiler. [Swift 6.3.3 release announcement](https://forums.swift.org/t/announcing-swift-6-3-3/87888).
- AI requires an eligible Apple silicon Mac, Apple Intelligence enabled, a supported language, and the on-device model downloaded. Everything else works without AI.

## Build and run

Open `OpenRay.xcodeproj` and run the **OpenRay** scheme, or build a locally ad-hoc-signed app:

```sh
xcodebuild -project OpenRay.xcodeproj -scheme OpenRay \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
open DerivedData/Build/Products/Debug/OpenRay.app
```

The checked-in project includes source folders automatically; XcodeGen is not required. `project.yml` is retained for optional project regeneration. Distribution outside your own Mac requires appropriate Developer ID signing and notarization.

OpenRay opens a floating launcher and stays in the menu bar after dismissal. Press **⌥ Space** to toggle it. If another application owns that shortcut, choose an alternative in Settings. Keep the app at a stable location before enabling launch at login or granting Accessibility; ad-hoc-signed development rebuilds may need authorization again.

If Accessibility is enabled in System Settings but OpenRay still reports it unavailable, first quit and reopen the same build, then use **Settings → Refresh Status**. A saved grant can refer to an older ad-hoc code signature even while its switch remains on. In that case, remove only OpenRay's entry from the Accessibility list and add the exact current `.app` again, then enable it. This refreshes the system permission; it does not delete the application or its library. Avoid rebuilding or switching between Debug and Release while checking the grant.

## Included functionality

| Feature | Behavior |
| --- | --- |
| Launcher | Fuzzy app and command search, installed app icons, favorites, recents, keyboard navigation, and a contextual action menu. |
| Command bindings | Globally unique aliases and standard global hotkeys for a curated set of frequent commands, configured in Settings. |
| Applications | Discovers user/system Applications folders and Finder; launches using `NSWorkspace`. Refresh the index in Settings after installing apps. |
| Files | Spotlight filename search in your home folder, with recent results, open, reveal in Finder, copy path, and favorites. Explicitly filters Library, hidden paths, app contents, `node_modules`, and DerivedData. Requires Spotlight indexing and normal macOS folder access. |
| Calculator | Arithmetic, parentheses, powers, percentages, scientific functions, and unit conversions for length, mass, duration, temperature, storage, and volume. Uses a bounded parser, never shell or expression evaluation. |
| Clipboard | Opt-in history for text, images, and grouped file references, with type filters, previews, format-aware copy/direct paste, deduplication, retention, exclusions, and deletion. Pausing capture preserves access to saved history. |
| Snippets | Create, edit, search, copy, and paste reusable text. Optional keyword expansion across apps, with `{date}` and `{time}` placeholders. |
| Quicklinks | Named URLs, local files/folders, and web search templates using `{query}`. Keywords support queries such as `web swift concurrency`. Query arguments are percent-encoded. |
| Notes | Create, edit, search, copy, and delete local notes. AI responses can be explicitly saved as notes. |
| Windows | Halves, quarters, maximize, center, next display, and restoration of the original frame, using macOS Accessibility APIs. |
| AI | Streaming chat, summarization, rewriting, proofreading, shortening, and action-item extraction through Apple’s on-device Foundation Models framework. |
| Settings | Launcher shortcut, appearance, login item, clipboard retention/exclusions, optional snippet expansion, permission/model status, and library location. |

Try `6 * 7`, `200 * 15%`, `sqrt(144)`, `10 km in mi`, `72 f in c`, or `1 GiB in MiB`. Trigonometric functions take radians; `%` divides the preceding value by 100. Storage units distinguish decimal MB/GB from binary MiB/GiB. Gallons are US gallons. Live currency rates and natural-language date calculations are not implemented.

### Keyboard controls

- **↑ / ↓**: select a result. **Return**: open or copy it.
- **⌘K**: contextual actions. **⌘Return**: paste a text result into the previously active app, when permitted.
- **⌘N**: create a snippet, quicklink, or note in its library; start a new AI conversation in AI.
- **⌘S**: save an editor. **⌘,**: Settings.
- **Escape**: close actions, return from a feature, clear the root query, or dismiss the launcher.
- In AI, **Return** inserts a newline and **⌘Return** sends. **Stop** cancels generation.

### Command aliases and hotkeys

In **Settings → Command aliases & hotkeys**, edit a command to set an alias, record a shortcut, or remove its binding. The supported commands are Applications, Files, Clipboard History, Snippets, Quicklinks, Notes, Calculator, Window Management, Ask AI, Settings, Left Half, Right Half, Maximize, Center, and Restore Window. Window commands retain their existing Accessibility and focused-window checks. Individual apps, quicklinks, clipboard entries, snippets, and other AI/window actions are outside this initial curated list.

An exact alias match wins in every launcher search section, ignoring case and surrounding whitespace. Aliases must be a single token of up to 32 characters and cannot duplicate another alias or a quicklink/snippet keyword. Existing command names still work through ordinary search. Bindings are saved in the local library and survive restart; older libraries retain their launcher shortcut preference.

Shortcuts use a physical key position plus Command, Control, Option, and/or Shift. Their label follows the current keyboard layout. Modifier-only gestures, separate left/right modifiers, and all-four-modifier Hyper shortcuts are unsupported. Known reserved macOS combinations and enabled system symbolic shortcuts are blocked. Other detected conflicts require **Save Anyway**; macOS does not expose every application's shortcuts. The launcher has priority over command bindings, followed by command bindings in saved order. A conflicting binding can remain saved but inactive, with an explanation in Settings. Removing the active binding lets the next saved assignment register.

If registration fails, the working launcher shortcut is preserved when possible, and **OpenRay's menu bar → Open OpenRay** remains available. Recording temporarily pauses OpenRay's shortcuts until a key is captured or recording is canceled. Saving or removing a binding updates registrations immediately.

## Permissions and privacy

Clipboard capture and automatic snippet expansion are **off by default**. OpenRay does not request Accessibility at launch. Enable it explicitly in Settings only if you want window layouts, direct paste, selected-text import, or keyword expansion. Password/security input is not a supported target for expansion or direct paste.

macOS also controls background clipboard reads separately. It may ask for permission after capture is enabled. After an app has triggered its first access alert, macOS exposes its per-app clipboard access in System Settings; **Always Allow** enables uninterrupted history. A denied or confirmation-required state is shown in OpenRay, which never changes the system permission itself. See [Apple’s pasteboard access documentation](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum).

Clipboard capture skips the concealed, transient, and auto-generated pasteboard markers, known password-manager bundle identifiers, and Secure Input. These are best-effort safeguards, not a secret detector: unmarked sensitive content can still be copied by other apps. Add exclusions or pause capture when appropriate. Image and file capture have separate toggles. Existing version-1 libraries keep their text-only capture choice until those toggles are explicitly enabled.

Source-app labels and app exclusions use the foreground application observed when the clipboard is polled; switching apps immediately after copying can affect that attribution. Confidential-content markers are checked independently.

Default retention is seven days / 100 entries, with a configurable maximum of 500 entries and a 64 MB content budget. Text entries are limited to 128 KB. PNG/TIFF input is normalized to PNG off the main actor: up to 64 MB of source data, 40 megapixels, and 10 MB per saved image. Previews use bounded thumbnails. Up to 100 copied files are grouped into one entry; only their URLs are saved, so the originals must remain available. File contents are not copied, moved, or deleted by history cleanup. Text is currently preserved as plain text, not RTF/HTML.

The library is stored at:

```text
~/Library/Application Support/OpenRay/library.json
~/Library/Application Support/OpenRay/ClipboardImages/
```

The metadata is local JSON and images are separate, content-addressed PNG files, **not application-level encrypted**. Application directories are owner-only (`0700`) and files are owner-readable/writable (`0600`). Saves are atomic. Invalid or newer libraries are preserved and shown as read-only with an error instead of being overwritten. Version-1 data migrates without discarding existing notes or text history. Image cleanup follows history deletion/expiry; clearing or pausing capture also prevents an in-flight image from being saved afterward. Missing or corrupted image data is reported without erasing the current clipboard. Deleted notes/snippets/links/history have no in-app undo; confirmations are shown. Back up the JSON and image directory together if needed.

AI uses [Apple’s Foundation Models framework](https://developer.apple.com/documentation/foundationmodels) with no API key and no cloud fallback. Clipboard or selected text is included only when you click its import button. Conversations remain in memory until you quit or start a new conversation; only an explicit **Save as Note** writes a response to disk. Input is limited to 6,000 characters, and context-limit errors start a fresh session with a visible explanation. The model is not a web search, source of live facts, or autonomous system agent; always review generated text.

OpenRay is not App Sandbox-enabled because its core features integrate with other applications and the global clipboard. macOS privacy permissions still apply. The app does not include analytics, an extension marketplace, cloud sync, or third-party AI providers.

## Verification

Run the deterministic tests (no permission prompts, private test pasteboards, isolated temporary libraries):

```sh
./scripts/verify.sh
```

On a Mac with Apple Intelligence ready, also run the actual model integration test:

```sh
./scripts/verify.sh --ai
```

The suite covers search and stable selection, command alias uniqueness/ranking, binding migration and persistence, reserved-key validation, shortcut registration lifecycle/failure recovery with an isolated backend, in-process Carbon event routing, URL escaping, arithmetic/conversions, persistence and corrupt-file preservation, clipboard opt-in/exclusions/retention, PNG/TIFF capture and restore, grouped file references, media storage/cleanup, migration, in-flight cancellation, snippet matching and Unicode insertion chunks, multi-display geometry, and AI streaming/cancellation/context recovery. Live window manipulation, global shortcut delivery, and cross-app text expansion still require interactive OS-level verification with the relevant permissions.

For UI verification without writing test notes or snippets into the normal library, launch the executable with `--in-memory-library`. This uses the real services and model, but discards library edits on exit. `scripts/ui-smoke.mjs` contains Computer Use regression checks for initial focus, focus restoration after editor dismissal, and rapid typing after Back. The floating panel uses small AppKit input adapters to manage actual first-responder changes without timing-based focus resets.

For clipboard UI checks without touching the General pasteboard, also pass `--verification-pasteboard OpenRayVerification.NAME`. This flag is accepted only with an in-memory library and a dedicated name; invalid configurations fail closed. `scripts/clipboard-fixture.swift` can supply an image or file references to that private pasteboard, describe its formats, and release it afterward. Cross-app paste, global hotkey registration, snippet expansion, and login-item changes are disabled in this mode, which is labeled in the UI. When multiple builds exist, pass the full `.app` path to the Computer Use smoke checks.

The app icon is generated deterministically from vector drawing code. To regenerate its asset sizes:

```sh
swift scripts/generate-app-icon.swift
```
