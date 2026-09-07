# OpenRay release guide

Reviewed against Apple documentation on 7 September 2026. The selected distribution route is a **direct download signed with Developer ID and notarized by Apple**. This guide describes the release requirements; it is not evidence that a particular binary has passed them.

For automated builds and publication, use the [GitHub release pipeline](GITHUB-RELEASES.md). It applies the packaging checks below to Apple silicon builds, prepares draft assets, verifies downloads, and publishes SemVer releases with a latest-stable link.

## Distribution decision

Direct distribution preserves OpenRay's window management, selected-text import, and optional cross-app text insertion. Apple requires Mac App Store apps to use App Sandbox; Apple's sandbox documentation lists assistive Accessibility API use as incompatible. The current implementation calls `AXUIElement` to inspect and control other applications. Merely enabling the sandbox build setting would not make that product work correctly. [App Review Guidelines, 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility), [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

App Sandbox and Hardened Runtime are separate controls. Keep Hardened Runtime enabled for this direct build. macOS still requires the user's permission for protected operations. Notarization is Apple's automated distribution security check; it does not constitute App Store review or approval. [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

If a Mac App Store edition is considered later, treat it as a separate product scope: remove or redesign cross-app Accessibility features, constrain file access to authorized locations with persistent security-scoped access where needed, and validate the complete sandboxed user experience. Do not describe every global input API as incompatible: Apple DTS demonstrates a sandboxed **listen-only** event tap with explicit Input Monitoring consent. That example does not establish support for OpenRay's event injection and Accessibility features. [Apple DTS event-tap example](https://developer.apple.com/forums/thread/724608).

## Owner inputs

These values cannot be inferred from the source or replaced with development credentials:

| Input | Needed for |
| --- | --- |
| Apple Developer Program team and a usable Developer ID Application identity | Signing the release. The certificate must have its corresponding private key available to the signing workflow. An Apple Development identity is insufficient. |
| Authorized notarization authentication, stored in a Keychain profile | Submitting the signed artifact to Apple. Use an app-specific password or a supported App Store Connect API key; keep secrets out of source control and release logs. |
| Publisher and release ownership | Confirming the signing publisher and any release/licensing terms. The source does not establish the publisher's legal identity. |
| Public HTTPS download location | Publishing the final artifact. The existing public GitHub repository and issue tracker provide documentation and issue reporting. |
| Final version/build, release notes, supported architectures, and licensing terms | Identifying exactly what customers receive. Confirm rights to the name, icon, and included material before release. |
| Website/download/support providers and their data practices | Completing the public privacy notice for services outside the app. The source code cannot establish their logging or retention. |

Create or obtain a Developer ID Application certificate through the team's authorized workflow. Developer ID Installer is for an installer package and does not replace the app-signing identity. Apple documents Account Holder access for manually creating Developer ID certificates and separate authorization for cloud-managed certificates. [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

For a local workflow, inspect available signing identities:

```sh
security find-identity -v -p codesigning
```

Set up a notarization profile interactively so the secret is entered at a secure prompt:

```sh
xcrun notarytool store-credentials OpenRay-notary
```

The profile name is an example local label, not a credential included in this repository. Follow the prompts for your own account or API key. Apple's migration guide describes the Keychain profile workflow; `xcrun notarytool store-credentials --help` describes the installed tool's options. [TN3147: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

## Run the packaging script

Run from the repository root. Use the exact installed certificate name shown by `security find-identity`; the signing name and team below are illustrative values to replace:

```sh
export OPENRAY_SIGNING_IDENTITY='Developer ID Application: Your Publisher (TEAMID)'
export OPENRAY_NOTARY_PROFILE='OpenRay-notary'
./scripts/package-release.sh
```

The default mode verifies credentials, runs deterministic tests, archives an Apple silicon (`arm64`) app, signs it, and notarizes both the app and DMG. It produces a ZIP and an Applications-drag-install DMG with the stapled app, final checksums, logs, and the original archive. Outputs go to a new timestamped directory under `.build/releases/`; use `--output NEW_DIRECTORY` to choose another location. Existing output directories are refused.

To inspect the packaging locally before Developer ID credentials are available:

```sh
./scripts/package-release.sh --preview
```

Preview artifacts are ad hoc signed and explicitly labeled `local-preview`. They have no Developer ID signature or notarization and must not be published as a production download. `--skip-tests` is available only when the exact source revision has already passed `./scripts/verify.sh`; it does not skip package validation. The script never publishes its output. See [the packaging script](../scripts/package-release.sh) for the complete interface.

## Release pipeline and acceptance checks

1. Run `./scripts/verify.sh`. Run `./scripts/verify.sh --ai` on a Mac where Apple Intelligence is ready. Record the commit, version/build, Xcode/macOS versions, architectures, and results. The real-model check is conditional on local model availability; it is not replaced by the deterministic AI tests.
2. Create a Release archive, stage its app, and sign the staged app for Developer ID distribution. Require a valid Developer ID Application signature, Hardened Runtime, a secure signing timestamp, and no `com.apple.security.get-task-allow` entitlement set to true. Sign every executable included in the distribution. Do not add Hardened Runtime exceptions unless an actual feature requires and validates them. [Apple notarization prerequisites](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
3. Submit a supported container with `notarytool`, retain the submission ID, and require an `Accepted` result. Download and inspect its JSON log even on success. An upload acknowledgment is not acceptance.
4. Staple the ticket to the app and validate it. ZIP files cannot carry a stapled ticket directly: create the customer ZIP **after** stapling the enclosed app. If distributing a DMG, package and validate that final container as well. [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
5. Verify the final app's signature and distribution policy, then check the actual downloaded package on a clean supported Mac. Passing notarization does not prove all Gatekeeper checks or application behavior succeed. [Apple DTS on notarization and Gatekeeper](https://developer.apple.com/forums/thread/814949).
6. Preserve the exported app, archive/dSYMs, notary log and ID, final artifact checksum, and test record. Publish only the verified artifact; any subsequent code/resource change requires rebuilding and repeating the relevant signing and notarization steps.

Useful final-app checks, with `OPENRAY_RELEASE_APP` set to the actual exported app path:

```sh
codesign --verify --deep --strict --verbose=2 "$OPENRAY_RELEASE_APP"
codesign -dvvv --entitlements - "$OPENRAY_RELEASE_APP"
xcrun stapler validate "$OPENRAY_RELEASE_APP"
syspolicy_check distribution "$OPENRAY_RELEASE_APP"
```

`--deep` is used here for verification, not as a replacement for correctly signing nested code. Inspect the signature for the expected publisher/team, runtime flag, timestamp, and entitlements. Do not publish a local ad hoc or development-signed package as a production download.

## Manual release smoke test

OpenRay's supported hardware is Apple silicon; this release does not include Intel support. Use the signed, notarized release installed at a stable location in Applications. Test with a fresh user account or clean Mac/VM and download through a browser so normal quarantine and Gatekeeper checks apply. Keep the minimum supported macOS version and current shipping macOS in the release matrix. Verify the packaged executable is `arm64`, and use a physical eligible Mac for Apple Intelligence checks.

- **Install and lifecycle:** Download/extract or mount/install, launch from Finder, dismiss and reopen from the menu bar, quit fully, relaunch, and replace an older release while preserving its library. Confirm the displayed version/build matches the download. Repeat first launch without a network connection after downloading; the stapled app must remain usable.
- **Permission defaults:** A fresh library starts with clipboard capture and automatic snippet expansion off. Launch does not request Accessibility. Declining Accessibility leaves app launching, calculation, notes, and ordinary copy usable. Verify enabling and revoking Accessibility updates status without a crash or misleading success message.
- **Launcher and input:** Exercise all offered hotkeys and a conflicting shortcut, keyboard navigation, Command-K actions, editor save/cancel, focus restoration, and rapid typing. Check light/dark appearance and VoiceOver labels/focus. Confirm closing the launcher does not quit its menu-bar process.
- **Files and links:** Search an indexed test folder, open/reveal/copy its path, try an unavailable or protected location, and confirm errors are useful. Hidden paths, Library, app contents, `node_modules`, and DerivedData must stay excluded. Exercise a web quicklink with spaces, Unicode, `&`, and `#`; no request should be opened until the user executes the link.
- **Clipboard:** Enable capture and exercise allow/deny/ask system access states. Test plain text, PNG/TIFF, copied files, excluded apps, concealed content markers, and Secure Input. Pause capture, restore a saved entry, delete one entry, clear history, and confirm pruning removes owned images without touching original files. Revoking capture must prevent in-flight image work from saving later.
- **Accessibility features:** With explicit permission, test direct paste and Unicode snippet expansion into a disposable document. Switch focus during a pending paste and confirm OpenRay does not paste into the wrong target. Verify no insertion in Secure Input. Test window layouts, restore, fixed-size windows, full-screen failure, and multiple displays.
- **AI:** Exercise unavailable/not-enabled states, successful streaming, explicit clipboard/selected-text import, Stop, new conversation, context/input limits, and Save as Note. Confirm ordinary features work without AI. Restart and verify chats are not persisted unless explicitly saved as a note.
- **Persistence and cleanup:** Create disposable notes/snippets/links, relaunch, and verify them. Confirm the corrupt/newer-library warning preserves the original file. Check consent-driven launch-at-login enable/disable and quit behavior. Use the documented uninstall process on a disposable library.

Record pass/fail and the tested build for each group. Simulator, unit-test, or unsigned debug results do not establish that the release's system permissions work.

## Privacy and public release material

[Privacy information](privacy-policy.md) and [support](support.md) describe verified app behavior. The app links to the existing [public guide](https://github.com/alisoliman/openray#readme) and [public issue tracker](https://github.com/alisoliman/openray/issues). Publish these documentation changes with the release. Do not claim the app never stores data: its library, history, and usage-based recents are local persistent data. Web quicklinks deliberately send their URL/query to the user's selected external application and then to the destination service when that application opens it. A future standalone download site needs its actual hosting/data practices documented separately.

Apple's current required-reason API overview names iOS, iPadOS, tvOS, visionOS, and watchOS; it does not list macOS. A privacy manifest is not listed among Developer ID notarization prerequisites. Do not invent API-reason declarations just to fill a file. Reaudit if the distribution channel, supported platforms, APIs, or SDK dependencies change. [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

The source audit found no third-party SDK dependency or direct network client, account, analytics, advertising, or cloud AI implementation. Preferences are serialized with the library, not `UserDefaults`. File search reads Spotlight metadata; that alone does not identify a listed required-reason API. This is a source-level finding, not a completed binary/network audit. Apple's App Store definition of collection focuses on off-device transmission accessible to the developer or partners, but any later App Store privacy declaration must account for the actual final product and services. [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).
