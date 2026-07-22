import XCTest
@testable import CodexLimits

final class UsageWindowValidationTests: XCTestCase {
    func testRejectsRemainingPercentageIncreaseWithinSameWindow() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let previous = UsageWindow(
            remainingPercent: 52,
            resetsAt: reset,
            durationMinutes: 10_080
        )
        let stale = UsageWindow(
            remainingPercent: 87,
            resetsAt: reset,
            durationMinutes: 10_080
        )

        XCTAssertFalse(stale.isPlausibleSuccessor(to: previous))
    }

    func testAcceptsFurtherUsageWithinSameWindow() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let previous = UsageWindow(
            remainingPercent: 52,
            resetsAt: reset,
            durationMinutes: 10_080
        )
        let current = UsageWindow(
            remainingPercent: 50,
            resetsAt: reset,
            durationMinutes: 10_080
        )

        XCTAssertTrue(current.isPlausibleSuccessor(to: previous))
    }

    func testAcceptsIncreaseAfterResetWindowAdvances() {
        let previousReset = Date(timeIntervalSince1970: 2_000_000)
        let previous = UsageWindow(
            remainingPercent: 2,
            resetsAt: previousReset,
            durationMinutes: 10_080
        )
        let reset = UsageWindow(
            remainingPercent: 100,
            resetsAt: previousReset.addingTimeInterval(7 * 24 * 60 * 60),
            durationMinutes: 10_080
        )

        XCTAssertTrue(reset.isPlausibleSuccessor(to: previous))
    }

    func testTreatsSmallResetTimestampDriftAsSameWindow() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let previous = UsageWindow(
            remainingPercent: 52,
            resetsAt: reset,
            durationMinutes: 10_080
        )
        let stale = UsageWindow(
            remainingPercent: 87,
            resetsAt: reset.addingTimeInterval(2),
            durationMinutes: 10_080
        )

        XCTAssertFalse(stale.isPlausibleSuccessor(to: previous))
    }

    func testRemovesRepeatedStaleIncreasesFromSavedHistory() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(observedAt: Date(timeIntervalSince1970: 1), remainingPercent: 52, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 2), remainingPercent: 87, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 3), remainingPercent: 87, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 4), remainingPercent: 50, resetsAt: reset)
        ]

        let filtered = UsageReadingValidation.removingImplausibleIncreases(from: samples)

        XCTAssertEqual(filtered.map(\.remainingPercent), [52, 50])
    }
}
