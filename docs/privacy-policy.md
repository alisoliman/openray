# OpenRay privacy information

Last updated: 26 November 2026. This notice describes the OpenRay application and its public GitHub help links. It does not describe a separate download website or support service that is not part of this repository.

## What OpenRay does with your data

OpenRay is a local macOS launcher. Its current app implementation has no account system, advertising, analytics SDK, cloud sync, or cloud AI provider. It does not upload your local library to an OpenRay server.

OpenRay makes one kind of network request of its own, and only after you turn it on: currency conversion can download the European Central Bank's daily reference rates (Settings → Calculator). It is off by default, checks at most once a day, sends no data about you beyond the request itself, and keeps the rates in `currency-rates.json` beside your library. Everything else in this notice stays on your Mac unless you open a link, paste into another app, or export an archive yourself.

The app stores your notes, snippets, quicklinks, favorites, settings, and recent-use records on your Mac. Recent-use records include item identifiers, counts, and last-used times to support recents and ranking. Identifiers may contain application identifiers or file paths. The app scans standard Applications locations to list installed apps and uses Spotlight for filename search. The current file-search result list is kept in memory; a file you favorite or use can also be represented in your saved library records.

## Pomodoro

Pomodoro configuration, timer state, and completed focus sessions are stored in the local JSON library. State includes the current phase, its deadline or paused remaining time, and progress through the cycle. Completed-session records include timing and duration information used to show daily progress and the latest 20 sessions. Older records remain in the library, and resetting the cycle preserves them. OpenRay does not monitor the content of your work or share these records with a server. Timer state is restored after relaunch, including completion of an overdue phase.

Caffeinate holds a macOS power assertion while it's on and stores nothing; quitting OpenRay releases it.

## Clipboard history

Clipboard capture is off until you enable it. When enabled, it can save copied text, images, and file references, depending on your settings. Entries include the copy time and the app name/bundle identifier observed in the foreground when OpenRay polls the clipboard. Switching apps immediately after copying can affect that source label and app-based exclusion.

OpenRay skips supported concealed, transient, and auto-generated pasteboard markers, the app exclusions in Settings, and capture while Secure Input is active. These checks are best-effort safeguards. Unmarked sensitive content can still be saved, so use app exclusions or pause capture when needed. Image and file capture have their own toggles. macOS also controls clipboard access; OpenRay respects the system's access decision.

The defaults retain up to 100 entries for seven days, subject to the content budget. Settings offers retention of 1, 7, or 30 days and limits of 50, 100, 250, or 500 entries. The app enforces a 64 MB history-content budget. While running, it checks for expired history periodically, including when capture is paused, and when settings are applied or the launcher reopens. It cannot remove expired content while it is not running.

Images are saved as PNG files. For copied files, the app stores references to the originals, not copies of the files' contents. Removing history or pruning it does not delete those originals. Pausing capture stops new collection but leaves existing history available; use Clear History to remove saved history. Clearing OpenRay history does not erase the current macOS system clipboard.

## Accessibility and text expansion

OpenRay requests Accessibility access only when you explicitly choose to enable it. This allows supported window movement/resizing, selected-text import, direct paste, and optional keyword expansion in other applications. You can revoke access in System Settings.

Automatic snippet expansion is off by default. When enabled, it observes keyboard input to match your snippet keywords. Its matching buffer holds only a bounded recent suffix in memory; it does not write a transcript of your typing to disk. Secure Input and configured app exclusions suppress expansion.

When you choose a writing command, a `{selection}` placeholder or an AI Command that uses the selection, OpenRay reads the text selected in the app you opened it from, with that app and the text's place, and keeps them in memory for that task so the result can go back to the same place. Protected text fields and Secure Input are refused. OpenRay checks the original selection before replacing it; if it has changed, the result is copied instead. Starting a new chat, choosing another passage or inserting the result releases that target. Selected text is not read just because you open the launcher, and it is not saved to the library.

## Apple Intelligence

AI text generation uses Apple's on-device Foundation Models implementation. OpenRay has no cloud fallback or external AI API key. The feature requires an eligible Mac and an available Apple Intelligence model. [Apple's SystemLanguageModel documentation](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).

Your typed AI prompt and the content you choose to work on are processed by the on-device model. A writing command can use selected text as described above; Ask does not import a selection automatically. Clipboard, files, notes and screen captures reach the model when you attach or @-mention them, and an agent you give tools can read the library items those tools cover; every write or action a tool takes asks you first. Follow-up instructions use the writing result already in the conversation. Conversations in the launcher, drafts, and captured selection context remain in memory; how long the launcher keeps its place after hiding follows Settings → General → Back to Everything. The AI Chat window saves its chats on this Mac in `AIChats/chats.json`, which you can delete from the window or its Recently Deleted. Choosing Save as Note saves the selected AI response as a regular local note. Dictation, when you turn it on, uses the microphone and Apple's on-device speech recognition. Apple controls the model's installation and operating-system services under its own terms and privacy practices.

## Links and other applications

Executing a quicklink opens its URL in the appropriate application. Web-search quicklinks include the search terms you enter in the URL, so your browser and the destination website receive that request. OpenRay includes editable shortcuts for DuckDuckGo and GitHub and allows you to create your own links. Those services' privacy practices apply when you use them. A mail link opens your mail application; it does not send a message automatically.

Opening a file or app passes the selected item to macOS or the target application. Copying or pasting content makes it available to the system clipboard or the selected receiving application. These user-initiated actions intentionally share the selected content with that destination.

## Local storage and deletion

For the direct-download app, the default library is stored in:

```text
~/Library/Application Support/OpenRay/library.json
~/Library/Application Support/OpenRay/ClipboardImages/
```

Beside the library, OpenRay can also keep:

- `NoteAssets/` and `NoteRecovery/`: images pasted into notes, and copies kept while a note can still be restored from Recently Deleted.
- `AIChats/chats.json`: chats saved by the AI Chat window.
- `launcher-memory.json`: which result you picked for a search, and recent searches when search history is on.
- `local-approvals.json`: the script folders and deeplink commands you allowed on this Mac. It never travels in an archive.
- `backup-settings.json`: the folder and schedule for automatic backups, when you set them. Backups are encrypted archives written to the folder you choose, which can be in iCloud Drive; that folder's own sync and retention then apply.
- `screenshots.json`: text recognized in your screenshots, for Search Screenshots.
- `currency-rates.json`: the opt-in exchange rates described above.
- `library-pending-cleanup.json`: a short record that lets an interrupted deletion finish.

Archive export writes only the categories you choose, encrypted when you set a passphrase. Calendar access, when you grant it, is read on demand to show your schedule and is not copied into the library.

The JSON library and saved PNG images are not encrypted by OpenRay. The app applies owner-only permissions to its data directories and files, but local system access, device backups, and other software with sufficient access can affect their confidentiality. Device encryption and backups are controlled separately by you and macOS.

Delete notes, snippets, quicklinks, and clipboard history from the app to remove their saved records. To remove the entire local library, quit OpenRay, use Finder's Go to Folder to open `~/Library/Application Support/`, and move the `OpenRay` folder to Trash. Emptying Trash is a separate action. Keep a backup first if you may need the data. Removing the app alone does not remove that library. Copies in backups and content previously shared with other apps or websites must be managed separately.

## Help and public issue reporting

The app's guide and support links open the [OpenRay GitHub repository](https://github.com/alisoliman/openray) and its [public issue tracker](https://github.com/alisoliman/openray/issues) in your browser. OpenRay does not automatically attach your library, clipboard, or diagnostics. If you submit an issue, GitHub receives what you submit and the public post can be read by others. Do not post private notes, clipboard content, personal file paths, credentials, or unredacted library files. GitHub's own privacy practices apply to use of its website.

If a separate website, private support channel, updater, analytics service, or cloud feature is introduced, update this notice to explain that service's actual data handling. The application's local storage statements must not be extended to an unreviewed external service.

Implementation basis: `LibraryModels.swift`, `LibraryStore.swift`, `LibraryArchive.swift`, `LauncherMemory.swift`, `PomodoroModels.swift`, `PomodoroService.swift`, `CaffeinateService.swift`, `ClipboardService.swift`, `ClipboardImageStore.swift`, `SnippetExpander.swift`, `SelectedTextContext.swift`, `CurrencyRates.swift`, `LocalApprovals.swift`, `ScreenshotIndex.swift`, `ApplicationCatalog.swift`, `FileSearchService.swift`, `WindowManager.swift`, `ChatStore.swift`, `NoteExport.swift`, `AIChatModel.swift`, and `FoundationModelEngine.swift`. Recheck this notice whenever those data flows change.
