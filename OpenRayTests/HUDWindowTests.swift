import AppKit
import SwiftUI
import Testing

@testable import OpenRay

@MainActor
struct HUDWindowTests {
    private let laptop = WindowFixture.laptop.visibleFrame

    @Test func theHUDSitsCenteredLowOnTheDisplay() {
        let frame = HUDPlacement.frame(for: CGSize(width: 240, height: 88), in: laptop)
        #expect(frame == CGRect(x: 600, y: 172, width: 240, height: 88))
        let secondary = HUDPlacement.frame(for: CGSize(width: 300, height: 88), in: WindowFixture.secondary.visibleFrame)
        #expect(secondary.midX == WindowFixture.secondary.visibleFrame.midX)
        #expect(secondary.minY == CGFloat(-74))
        #expect(WindowFixture.secondary.visibleFrame.contains(secondary))
    }

    @Test func smallDisplaysKeepTheHUDOnScreen() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = HUDPlacement.frame(for: CGSize(width: 400, height: 88), in: small)
        #expect(frame == CGRect(x: 0, y: 12, width: 200, height: 88))
        #expect(small.contains(frame))
    }

    @Test func showingPresentsOnTheActiveDisplayAndHidesAfterTheDuration() {
        let presenter = FakeHUDPresenter()
        let timers = ManualSchedule()
        let controller = HUDController(presenter: presenter, screenFrame: { self.laptop }, schedule: timers.add)
        controller.show(message: "Trash emptied", symbol: "trash")
        #expect(presenter.presented.count == 1)
        #expect(presenter.presented.first?.message == HUDMessage("Trash emptied", symbol: "trash"))
        #expect(presenter.presented.first?.frame == CGRect(x: 600, y: 172, width: 240, height: 88))
        #expect(controller.current?.text == "Trash emptied")
        #expect(timers.delays == [.milliseconds(1_500)])
        #expect(HUDController.duration == .milliseconds(1_500))
        #expect(presenter.dismissals == 0)
        timers.fire(0)
        #expect(presenter.dismissals == 1)
        #expect(controller.current == nil)
    }

    @Test func aNewMessageReplacesTheCurrentOneAndRestartsTheTimer() {
        let presenter = FakeHUDPresenter()
        let timers = ManualSchedule()
        let controller = HUDController(presenter: presenter, screenFrame: { self.laptop }, schedule: timers.add)
        controller.show(message: "Volume 50%")
        controller.show(HUDMessage("Volume 56%", symbol: "speaker.wave.2.fill"))
        // The first message's timer runs out while the second is showing: nothing happens.
        timers.fire(0)
        #expect(presenter.dismissals == 0)
        #expect(controller.current?.text == "Volume 56%")
        timers.fire(1)
        #expect(presenter.dismissals == 1)
        #expect(presenter.presented.map { $0.message.text } == ["Volume 50%", "Volume 56%"])
    }

    @Test func hidingNowDismissesOnceAndDefusesTheTimer() {
        let presenter = FakeHUDPresenter()
        let timers = ManualSchedule()
        let controller = HUDController(presenter: presenter, screenFrame: { self.laptop }, schedule: timers.add)
        controller.show(message: "Muted")
        controller.hide()
        controller.hide()
        timers.fire(0)
        #expect(presenter.dismissals == 1)
        #expect(controller.current == nil)
    }

    @Test func withoutADisplayNothingIsShown() {
        let presenter = FakeHUDPresenter()
        let controller = HUDController(presenter: presenter, screenFrame: { nil }, schedule: ManualSchedule().add)
        controller.show(message: "Nowhere")
        #expect(presenter.presented.isEmpty)
        #expect(controller.current == nil)
    }

    @Test func messagesDefaultToSuccess() {
        let message = HUDMessage("Done")
        #expect(message.style == .success)
        #expect(message.symbol == nil)
    }

    @Test func theViewSizesToItsTextWithRoomForTheShadow() {
        let presenter = HUDPanelPresenter()
        let short = presenter.size(for: HUDMessage("Muted", symbol: "speaker.slash.fill"))
        let long = presenter.size(for: HUDMessage("Arranged 3 of 4 windows. No window for Music", symbol: "macwindow"))
        let margin = HUDView.shadowMargin * 2
        #expect(short.height >= 40 + margin)
        #expect(short.width > margin)
        #expect(long.width > short.width)
        #expect(long.width <= HUDView.maximumContentWidth + margin)
        let wrapped = presenter.size(for: HUDMessage(String(repeating: "Very long confirmation ", count: 8)))
        #expect(wrapped.width <= HUDView.maximumContentWidth + margin)
        #expect(wrapped.height > short.height)
    }

    @Test func theRealPanelNeverAppearsInTheTestHost() {
        let presenter = HUDPanelPresenter()
        presenter.present(HUDMessage("Hidden"), in: CGRect(x: 0, y: 0, width: 200, height: 80))
        #expect(!presenter.isVisible)
        presenter.dismiss()
        #expect(!presenter.isVisible)
    }
}

/// Holds HUD timers until a test fires them.
@MainActor
final class ManualSchedule {
    private var timers: [(delay: Duration, action: @MainActor @Sendable () -> Void)] = []

    var delays: [Duration] { timers.map { $0.delay } }

    func add(_ delay: Duration, _ action: @escaping @MainActor @Sendable () -> Void) {
        timers.append((delay, action))
    }

    func fire(_ index: Int) { timers[index].action() }
}
