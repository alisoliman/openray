import AppKit
import SwiftUI

/// Library archive commands: Back Up Library Now, and Export and Import, which open
/// Settings › Library. It also starts scheduled backups once the launcher first asks for commands.
@MainActor
final class LibraryArchiveProvider: CommandProvider {
    nonisolated static let registration = CommandProviderRegistration(id: "archive", bindablePrefixes: ["archive."]) {
        LibraryArchiveProvider()
    }
    nonisolated static let backUpID = "archive.backUpNow"
    nonisolated static let exportID = "archive.export"
    nonisolated static let importID = "archive.import"

    private var backupScheduler: LibraryBackupScheduler?
    private var startRequested = false

    var id: String { Self.registration.id }
    var title: String { "Library Archives" }

    init() {}

    /// The backup scheduler for this launcher's library, made on first use.
    func scheduler(for model: LauncherModel) -> LibraryBackupScheduler {
        if let backupScheduler, backupScheduler.store === model.store { return backupScheduler }
        let scheduler = LibraryBackupScheduler(
            store: model.store, settings: LibraryBackupSettingsStore(libraryURL: model.store.fileURL))
        backupScheduler = scheduler
        return scheduler
    }

    func commands(in model: LauncherModel) -> [CommandDescriptor] {
        if !startRequested {
            startRequested = true
            // Started on the next turn, so a view update never changes state.
            DispatchQueue.main.async { [weak self, weak model] in
                guard let self, let model else { return }
                self.scheduler(for: model).start()
            }
        }
        let settings = scheduler(for: model).settings.settings
        let subtitle: String
        if let folder = settings.folder {
            if let last = settings.lastBackupAt {
                subtitle = "Last backup \(last.formatted(.relative(presentation: .named))) · \(folder.lastPathComponent)"
            } else {
                subtitle = "Back up to \(folder.lastPathComponent)"
            }
        } else {
            subtitle = "Choose a backup folder in Settings › Library"
        }
        return [
            CommandDescriptor(
                id: Self.backUpID, title: "Back Up Library Now", subtitle: subtitle, kind: .system,
                symbol: "externaldrive.badge.timemachine", keywords: ["backup", "archive", "save", "library"],
                mode: .noView),
            CommandDescriptor(
                id: Self.exportID, title: "Export Library Archive", subtitle: "Save your library to one file, optionally encrypted",
                kind: .system, symbol: "square.and.arrow.up", keywords: ["export", "archive", "backup", "transfer", "move"],
                mode: .noView),
            CommandDescriptor(
                id: Self.importID, title: "Import Library Archive", subtitle: "Bring data in from an OpenRay archive",
                kind: .system, symbol: "square.and.arrow.down", keywords: ["import", "archive", "restore", "transfer"],
                mode: .noView),
        ]
    }

    func perform(_ item: LauncherItem, ref: ProvidedRef, in model: LauncherModel) {
        model.store.recordUse(of: item.id)
        switch ref.id {
        case Self.backUpID:
            let scheduler = scheduler(for: model)
            guard let folder = scheduler.settings.settings.folder else {
                model.panel?.dismiss(restoreFocus: false)
                model.openSettings(.library)
                return
            }
            model.feedback = .working("Backing up your library…")
            Task { [weak model] in
                do {
                    try await scheduler.backUpNow()
                    model?.toast("Backed up to \(folder.lastPathComponent)")
                } catch {
                    model?.feedback = .error("The backup failed. \(error.localizedDescription)")
                }
            }
        default:
            model.panel?.dismiss(restoreFocus: false)
            model.openSettings(.library)
        }
    }
}
