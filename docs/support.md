# OpenRay support

Report reproducible problems in the [OpenRay public issue tracker](https://github.com/alisoliman/openray/issues). The [project guide](https://github.com/alisoliman/openray#readme) contains current build and release information. Issues are public; remove personal information before posting.

## Install and open

OpenRay requires an Apple silicon Mac with macOS 26 or later. Intel Macs are not supported. Download the signed, notarized release from the publisher's official download location, extract the ZIP or open the disk image, and move OpenRay to Applications. Open it from Finder. Keep this copy in a stable location before granting permissions or enabling launch at login.

OpenRay runs in the menu bar. Press **Option-Space** to show or hide the launcher, or choose **Open OpenRay** in its menu. If the shortcut is already used by another app, choose another launcher shortcut in Settings. Use **Quit OpenRay** in its menu to exit; dismissing the launcher leaves it running.

If macOS reports an unidentified developer, a damaged app, or a verification failure, download the official release again and contact the publisher if the issue persists. A production release should pass Gatekeeper without disabling system security or removing quarantine attributes.

## Permissions and common issues

**Clipboard history is empty.** Enable capture in Settings, allow OpenRay's clipboard access when macOS asks, then copy a new item. Image and file capture have separate switches. Excluded apps, protected pasteboard markers, and Secure Input can prevent capture. The app reports clipboard access issues in Settings. Pausing capture keeps saved history available.

**Window management, direct paste, or selected-text import does not work.** Enable OpenRay under System Settings → Privacy & Security → Accessibility, then use Refresh Status in OpenRay Settings. If needed, quit and reopen the same installed copy. Some target apps do not expose selected text or permit their windows to be resized. You can still copy content and press Command-V manually in the receiving app.

**An old development permission no longer works.** A saved Accessibility grant may refer to a different app location or ad hoc development signature. Quit OpenRay, remove only its obsolete entry from the Accessibility list, add the exact installed release, and enable that entry. Avoid switching between development and release copies while troubleshooting.

**Snippet expansion does not work.** Enable automatic expansion and Accessibility, use a valid snippet keyword at a word boundary, and check app exclusions. Expansion is disabled during Secure Input and while Command, Control, or Option modifiers are held. For example, a snippet with keyword `;email` expands when that keyword is typed after a space or at the beginning of the matching buffer. Copying the snippet manually remains available.

**File search finds no results.** Search uses Spotlight filename indexing in your home folder and requires normal macOS access to the location. It excludes Library, hidden paths, app contents, `node_modules`, and DerivedData. Check Spotlight's indexing/privacy settings for the folder and try a filename with at least two characters. OpenRay does not index file contents itself.

**AI is unavailable.** AI requires an eligible Apple silicon Mac, Apple Intelligence enabled, a supported language, and the system model ready. Check the status in OpenRay Settings. Model preparation can take time after enabling Apple Intelligence. The rest of OpenRay remains available. AI does not browse the web, uses no cloud fallback, and may return inaccurate text; review its output.

**Launch at login is pending.** Enable it in OpenRay Settings, then approve OpenRay in macOS Login Items if prompted. Disable it in OpenRay Settings when it is no longer wanted.

## Pomodoro timer

Search **Start Pomodoro** to start or resume the current timer phase, or **Pomodoro** to open the timer and view today's completed sessions, focus minutes, and the latest 20 completed focus sessions. A new cycle begins with focus. Both commands can have aliases and global shortcuts in Settings. The menu bar shows the active countdown and offers timer controls; closing the launcher leaves the timer running.

The defaults are 25 minutes of focus, a 5-minute short break, and a 15-minute long break after every four completed focus sessions, with a daily goal of eight sessions. **Settings → Pomodoro** lets you adjust these values, enable automatic break starts, and choose whether to play a completion sound. Each focus session starts manually. Pause and resume to preserve remaining time, skip a break, or reset the cycle. Only fully completed focus sessions add to your progress. Changed durations apply to the next phase.

**The timer finished while the Mac was asleep or OpenRay was closed.** The saved deadline is checked when OpenRay runs again, and an overdue phase is completed then. If automatic break starts are enabled, the break begins when that completion is processed. OpenRay does not count unattended focus cycles or play a completion sound while it is closed. Your timer state and completed-session history are included in the local library backup.

## Back up, reset, and uninstall

Choose **Reveal Library in Finder** in Settings to locate the saved library. Quit the app before making a manual backup, and copy both `library.json` and the `ClipboardImages` folder together. AI conversations are not included unless you explicitly saved a response as a note.

If OpenRay says the library could not be loaded, preserve the original file before attempting repair or a reset. An invalid or newer library is left untouched rather than overwritten. Do not send a full library to support by default; it can contain sensitive notes, snippets, clipboard history, and file paths.

To uninstall, disable launch at login, quit OpenRay, and move the app from Applications to Trash. To also remove its saved local data, use Finder → Go → Go to Folder, enter `~/Library/Application Support/`, and move only the `OpenRay` folder to Trash. Empty Trash when ready. This removes all saved local library content and cannot be undone from the app. Device backups and the current system clipboard are managed separately.

## Request help

Open an issue in the [public issue tracker](https://github.com/alisoliman/openray/issues). Include the OpenRay version/build, macOS version, Mac chip, the action that failed, the exact visible error, and whether it happens repeatedly. A redacted screenshot can help. Do not include passwords, signing credentials, private clipboard content, or unredacted library files. OpenRay does not submit a report or attach data automatically when you open the support link.

See [privacy information](privacy-policy.md) for the current app's data handling.
