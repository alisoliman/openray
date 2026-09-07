# Release readiness — 7 September 2026

The selected product is a direct-download OpenRay app for **Apple silicon Macs on macOS 26 or later**. Intel and Mac App Store distribution are outside this release's scope. Cross-app functionality remains available with the user's macOS permissions.

**Status: locally validated release preview; production signing and notarization are pending.** No production release was uploaded or published. The preview must not be presented as a notarized download.

## Completed changes

- Both Xcode configurations, XcodeGen configuration, packaging, and installation guidance target `arm64`.
- The Actions menu uses native menu tracking, preserving the selected result while arrows, Return, and Escape navigate actions. Embedded Settings supports Escape; native Settings follows the chosen appearance.
- Built-in Help covers shortcuts, permissions, local data, AI behavior, and the verified public GitHub support channel. The auxiliary Help window is excluded from automatic launch and restoration.
- File-result accessibility includes identifying paths, editor inputs have explicit labels, and AI output renders inline emphasis without making generated links active.
- Clipboard retention continues while capture is paused. Successful library startup removes orphaned clipboard images; unreadable libraries preserve their image data.
- Writing commands have explicit transformation contracts. Proofreading and extraction use greedy sampling; quality remains subject to model limitations described below.
- The bundle includes a privacy manifest describing no tracking or collected data. The [privacy information](privacy-policy.md) distinguishes local persistence from external links and public support posts.
- [Packaging](../scripts/package-release.sh) creates an archive, ZIP, drag-to-Applications DMG, checksums, and logs. Production mode requires a Developer ID identity and notarization profile, verifies acceptance, staples tickets, and runs distribution-policy checks. Preview mode is distinctly labeled.

## Verification evidence

Environment: Xcode 26.6 (17F113), macOS 26.6.2 (25G83), physical Apple silicon Mac.

| Check | Result |
| --- | --- |
| Aggregate deterministic tests | 82 passed, 0 failed; 2 opt-in model tests skipped. 84 total test cases. |
| Final AI suite with `OPENRAY_TEST_AI=1` | 9 passed, 0 skipped, 0 failed, including actual on-device generation and quality-evaluation attachments. |
| Swift formatting, shell/JavaScript syntax, plist validation, whitespace | Passed for changed files. |
| Release archive | Successful; executable contains only `arm64`; hardened runtime enabled. |
| Preview bundle | Ad-hoc signature verifies; app icon and privacy manifest are present. |
| DMG | Integrity check passed; mounted read-only; enclosed app signature verified; Applications shortcut and install instructions present; volume detached afterward. |
| Interactive UI | Actions-menu arrow navigation retained Calculator as the target; Escape restored search; Escape from Settings immediately accepted `6 * 7` and displayed 42; Help opened from embedded Settings and native Help; native Settings visibly applied Light. |
| Production preflight without distribution credentials | Correctly refused to package a production download. |

The interactive app used a separate bundle identifier, an in-memory library, and a private verification pasteboard. Normal user library data and system permissions were not changed. Live cross-app paste, snippet expansion, global shortcut conflicts, launch-at-login changes, clean-machine Gatekeeper behavior, and minimum-OS coverage remain part of the signed-build smoke test in the [release guide](RELEASE.md). This validation does not certify every OS integration or VoiceOver interaction.

Local evidence (ignored build outputs, not committed release assets):

- `.build/verification/Logs/Test/Test-OpenRay-2026.09.07_12-00-10-+0200.xcresult` — deterministic run.
- `.build/verification/Logs/Test/Test-OpenRay-2026.09.07_12-01-22-+0200.xcresult` — final AI run.
- `.build/releases/release-candidate-preview/` — final preview archive, ZIP, DMG, checksums, and signature/package logs.
- `.build/releases/release-candidate-preview/ai-evaluation/` — exported model outputs and evaluation summary.

The final preview files are `OpenRay-0.1.0-local-preview.dmg` and `OpenRay-0.1.0-local-preview.zip`. Version/build remains 0.1.0 (1). The existing user-authored `UI-UX-REVIEW.md` was preserved.

## Known AI quality limitation

The bounded live evaluation includes already-correct proofreading, correction of a sentence with grammar errors, extraction of tasks with owners/dates, and a descriptive passage containing no tasks. Earlier runs exposed conversational filler, unnecessary tense changes, and descriptions being presented as action items. Revised instructions and sampling improved the first three fixtures; description-versus-task recognition still failed in an observed run. Passing the integration suite establishes that model streaming and reporting work, not that every generated answer is correct. Quality observations and exact outputs are recorded separately from deterministic service checks.

OpenRay already tells users to review generated text. It does not automatically execute extracted tasks or operate applications through AI. These limitations must remain visible in release notes and future model evaluations.

## Remaining release steps

1. Create or install a usable **Developer ID Application** signing certificate for the intended publisher. Inspection found only an Apple Development identity; Xcode offers Developer ID certificate creation for the personal developer team.
2. Authenticate notarization through Xcode or configure the Keychain profile documented in [RELEASE.md](RELEASE.md). Do not put passwords, private keys, or API secrets in chat or source control.
3. Sign and notarize the final source build, require Apple acceptance, staple and validate the app/DMG, and retain the logs. The signed stages have not yet been exercised with distribution credentials.
4. Run the signed-build installation and OS-permission smoke tests, then publish the verified artifacts and documentation to the chosen download location. This task has not published a GitHub release.
