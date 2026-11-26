import AppKit
import Testing

@testable import OpenRay

@MainActor
private final class CaffeinateTestAssertions: CaffeinatePowerAssertions {
    private(set) var createdIDs: [UInt32] = []
    private(set) var releasedIDs: [UInt32] = []
    private(set) var liveIDs: Set<UInt32> = []
    var failCreation = false
    var releaseFailuresRemaining = 0

    func create() throws -> UInt32 {
        if failCreation { throw CaffeinateTestError("Cannot create assertion") }
        let id = UInt32(createdIDs.count + 1)
        createdIDs.append(id)
        liveIDs.insert(id)
        return id
    }

    func release(_ id: UInt32) throws {
        releasedIDs.append(id)
        if releaseFailuresRemaining > 0 {
            releaseFailuresRemaining -= 1
            throw CaffeinateTestError("Cannot release assertion")
        }
        #expect(liveIDs.remove(id) != nil)
    }
}

private struct CaffeinateTestError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
private final class CaffeinateTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
struct CaffeinateTests {
    private func makeService(
        assertions: CaffeinateTestAssertions,
        clock: CaffeinateTestClock = CaffeinateTestClock(),
        automaticallyMonitors: Bool = false
    ) -> CaffeinateService {
        CaffeinateService(
            assertions: assertions, now: { clock.date },
            automaticallyMonitors: automaticallyMonitors)
    }

    @Test func durationsHaveStableChoicesAndMinuteValues() {
        #expect(CaffeinateDuration.allCases.count == 8)
        #expect(Set(CaffeinateDuration.allCases.map(\.id)).count == 8)
        #expect(CaffeinateDuration.indefinitely.seconds == nil)
        #expect(
            CaffeinateDuration.allCases.compactMap(\.seconds) == [600, 1_800, 3_600, 7_200, 14_400, 28_800, 43_200])
        #expect(CaffeinateDuration.allCases.allSatisfy { !$0.title.isEmpty })
    }

    @Test func constructionAndStoppingAnInactiveServiceDoNotCreateAssertions() {
        let assertions = CaffeinateTestAssertions()
        let service = makeService(assertions: assertions)
        #expect(!service.isActive)
        #expect(service.deadline == nil)
        #expect(service.remainingSeconds == nil)
        #expect(service.statusText == "Off")
        #expect(service.stop())
        service.shutdown()
        #expect(assertions.createdIDs.isEmpty)
        #expect(assertions.releasedIDs.isEmpty)
    }

    @Test func indefiniteStartAndRepeatedStartOwnExactlyOneAssertion() {
        let assertions = CaffeinateTestAssertions()
        let service = makeService(assertions: assertions)
        #expect(service.start())
        #expect(service.start())
        #expect(service.isActive)
        #expect(service.deadline == nil)
        #expect(service.remainingSeconds == nil)
        #expect(service.statusText == "On Indefinitely")
        #expect(assertions.createdIDs == [1])
        #expect(assertions.liveIDs == [1])
        #expect(service.stop())
        #expect(!service.isActive)
        #expect(assertions.releasedIDs == [1])
        #expect(assertions.liveIDs.isEmpty)
    }

    @Test func timedRestartReplacesDeadlineWithoutReleasingTheAssertion() {
        let assertions = CaffeinateTestAssertions()
        let clock = CaffeinateTestClock()
        let service = makeService(assertions: assertions, clock: clock)
        #expect(service.start(for: .tenMinutes))
        #expect(service.deadline == clock.date.addingTimeInterval(600))
        clock.date.addTimeInterval(40)
        #expect(service.start(for: .oneHour))
        #expect(service.deadline == clock.date.addingTimeInterval(3_600))
        #expect(service.remainingSeconds == 3_600)
        #expect(assertions.createdIDs == [1])
        #expect(assertions.releasedIDs.isEmpty)
        #expect(service.start())
        #expect(service.deadline == nil)
        clock.date.addTimeInterval(86_400)
        service.refresh()
        #expect(service.isActive)
    }

    @Test func countdownUsesDeadlineRoundsUpAndClampsBackwardClockChanges() {
        let assertions = CaffeinateTestAssertions()
        let clock = CaffeinateTestClock()
        let service = makeService(assertions: assertions, clock: clock)
        #expect(service.start(for: .tenMinutes))
        clock.date.addTimeInterval(1.1)
        service.refresh()
        #expect(service.remainingSeconds == 599)
        #expect(service.statusText == "On · 9:59 Remaining")
        clock.date.addTimeInterval(-10_000)
        service.refresh()
        #expect(service.remainingSeconds == 600)
    }

    @Test func exactDeadlineAndLongWakeGapBothExpireTheSession() {
        for elapsed in [600.0, 100_000.0] {
            let assertions = CaffeinateTestAssertions()
            let clock = CaffeinateTestClock()
            let service = makeService(assertions: assertions, clock: clock)
            #expect(service.start(for: .tenMinutes))
            clock.date.addTimeInterval(elapsed)
            service.refresh()
            #expect(!service.isActive)
            #expect(service.deadline == nil)
            #expect(service.remainingSeconds == nil)
            #expect(service.errorMessage == nil)
            #expect(assertions.releasedIDs == [1])
            service.refresh()
            #expect(assertions.releasedIDs == [1])
        }
    }

    @Test func customDurationBoundsAndInvalidValuesPreserveActiveSession() {
        let assertions = CaffeinateTestAssertions()
        let clock = CaffeinateTestClock()
        let service = makeService(assertions: assertions, clock: clock)
        #expect(service.start(minutes: 1))
        #expect(service.remainingSeconds == 60)
        #expect(service.start(minutes: 1_440))
        #expect(service.remainingSeconds == 86_400)
        let originalDeadline = service.deadline
        for invalid in [Int.min, -1, 0, 1_441, Int.max] {
            #expect(!service.start(minutes: invalid))
            #expect(service.isActive)
            #expect(service.deadline == originalDeadline)
            #expect(service.errorMessage?.contains("1,440") == true)
        }
        #expect(assertions.createdIDs == [1])
        #expect(assertions.releasedIDs.isEmpty)
        #expect(service.start(minutes: 10))
        #expect(service.errorMessage == nil)
    }

    @Test func invalidDurationWhileInactiveNeverCreatesAnAssertion() {
        let assertions = CaffeinateTestAssertions()
        let service = makeService(assertions: assertions)
        #expect(!service.start(minutes: 0))
        #expect(!service.isActive)
        #expect(service.deadline == nil)
        #expect(assertions.createdIDs.isEmpty)
    }

    @Test func creationFailureDoesNotClaimTheMacIsAwakeAndCanBeRetried() {
        let assertions = CaffeinateTestAssertions()
        assertions.failCreation = true
        let service = makeService(assertions: assertions)
        #expect(!service.start(for: .oneHour))
        #expect(!service.isActive)
        #expect(service.deadline == nil)
        #expect(service.remainingSeconds == nil)
        #expect(service.errorMessage == "Cannot create assertion")
        assertions.failCreation = false
        #expect(service.start(for: .oneHour))
        #expect(service.isActive)
        #expect(service.errorMessage == nil)
    }

    @Test func releaseFailureRetainsOwnershipAndRefreshRetriesTheSameAssertion() {
        let assertions = CaffeinateTestAssertions()
        let service = makeService(assertions: assertions)
        #expect(service.start())
        assertions.releaseFailuresRemaining = 1
        #expect(!service.stop())
        #expect(service.isActive)
        #expect(service.errorMessage == "Cannot release assertion")
        #expect(assertions.liveIDs == [1])
        service.refresh()
        #expect(!service.isActive)
        #expect(service.errorMessage == nil)
        #expect(assertions.releasedIDs == [1, 1])
        #expect(assertions.liveIDs.isEmpty)
    }

    @Test func expiryReleaseFailureStaysVisibleUntilTheAssertionIsReleased() {
        let assertions = CaffeinateTestAssertions()
        let clock = CaffeinateTestClock()
        let service = makeService(assertions: assertions, clock: clock)
        #expect(service.start(minutes: 1))
        let deadline = service.deadline
        assertions.releaseFailuresRemaining = 1
        clock.date.addTimeInterval(65)
        service.refresh()
        #expect(service.isActive)
        #expect(service.remainingSeconds == 0)
        #expect(service.deadline == deadline)
        #expect(service.errorMessage != nil)
        service.refresh()
        #expect(!service.isActive)
        #expect(assertions.liveIDs.isEmpty)
    }

    @Test func newStartAfterReleaseFailureKeepsTheAssertionAndCancelsStopRetry() {
        let assertions = CaffeinateTestAssertions()
        let service = makeService(assertions: assertions)
        #expect(service.start())
        assertions.releaseFailuresRemaining = 1
        #expect(!service.stop())
        #expect(service.start(for: .oneHour))
        service.refresh()
        #expect(service.isActive)
        #expect(service.remainingSeconds == 3_600)
        #expect(service.errorMessage == nil)
        #expect(assertions.createdIDs == [1])
        #expect(assertions.releasedIDs == [1])
    }

    @Test func toggleAlternatesAndShutdownReleasesOnlyTheOwnedAssertion() {
        let assertions = CaffeinateTestAssertions()
        let service = makeService(assertions: assertions)
        #expect(service.toggle())
        #expect(service.isActive)
        #expect(service.toggle())
        #expect(!service.isActive)
        #expect(service.toggle())
        #expect(service.isActive)
        service.shutdown()
        #expect(!service.isActive)
        #expect(assertions.createdIDs == [1, 2])
        #expect(assertions.releasedIDs == [1, 2])
        #expect(assertions.liveIDs.isEmpty)
    }

    @Test func destructionReleasesAnAssertionAndMonitoringDoesNotRetainService() {
        let assertions = CaffeinateTestAssertions()
        var service: CaffeinateService? = makeService(assertions: assertions, automaticallyMonitors: true)
        weak let weakService = service
        #expect(service?.start() == true)
        service = nil
        #expect(weakService == nil)
        #expect(assertions.liveIDs.isEmpty)
        #expect(assertions.releasedIDs == [1])
    }
}
