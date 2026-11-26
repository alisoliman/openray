import AppKit
import ApplicationServices
import QuickLookUI
import Testing

@testable import OpenRay

@MainActor
struct PanelAndWindowTests {
    @Test func openSettingsArgumentFallsBackToGeneral() {
        #expect(RuntimeMode.settingsPane(arguments: ["OpenRay"]) == nil)
        #expect(RuntimeMode.settingsPane(arguments: ["OpenRay", "--open-settings"]) == .general)
        #expect(RuntimeMode.settingsPane(arguments: ["OpenRay", "--open-settings", "shortcuts"]) == .shortcuts)
        // Another flag or a typo after it still opens Settings.
        #expect(RuntimeMode.settingsPane(arguments: ["OpenRay", "--open-settings", "--in-memory-library"]) == .general)
        #expect(RuntimeMode.settingsPane(arguments: ["OpenRay", "--open-settings", "shortcut"]) == .general)
    }

    @Test func quickLookPreviewServesOneFile() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let preview = QuickLookPreview(url: url)
        #expect(preview.numberOfPreviewItems(in: nil) == 1)
        #expect(preview.previewPanel(nil, previewItemAt: 0)?.previewItemURL == url)
    }

    @Test func launcherPanelControlsQuickLookOnlyWhilePreviewing() {
        let panel = LauncherPanel()
        #expect(!panel.acceptsPreviewPanelControl(nil))
        panel.quickLook = QuickLookPreview(url: URL(fileURLWithPath: "/tmp/report.pdf"))
        #expect(panel.acceptsPreviewPanelControl(nil))
    }

    @Test func shortAndOversizedFileSearchesDoNoWork() {
        let files = FileSearchService()
        defer { files.stop() }
        files.search("a")
        #expect(!files.isSearching)
        #expect(files.results.isEmpty)
        files.search(String(repeating: "a", count: 600), showRecent: true)
        #expect(!files.isSearching)
        files.search("report")
        #expect(files.isSearching)
        files.stop()
        #expect(!files.isSearching)
    }

    @Test func windowListingNeverIncludesOpenRay() {
        let windows = WindowManager()
        let listed = windows.listWindows()
        if windows.hasPermission {
            #expect(!listed.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
        } else {
            #expect(listed.isEmpty)
        }
    }

    @Test func arrangingAWindowOfOpenRayItselfFails() {
        let windows = WindowManager()
        let pid = ProcessInfo.processInfo.processIdentifier
        var error: (any Error)?
        do { try windows.arrange(.center, window: AXUIElementCreateApplication(pid), pid: pid) } catch let thrown {
            error = thrown
        }
        #expect(error is LibraryValidationError)
    }
}
