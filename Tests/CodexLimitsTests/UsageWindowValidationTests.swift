import XCTest
@testable import CodexLimits

final class UsageWindowValidationTests: XCTestCase {
    func testKeepsIncreasePendingWithoutConfirmation() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(observedAt: Date(timeIntervalSince1970: 1), remainingPercent: 25, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 2), remainingPercent: 31, resetsAt: reset)
        ]

        let filtered = UsageReadingValidation.removingImplausibleIncreases(from: samples)

        XCTAssertEqual(filtered.map(\.remainingPercent), [25])
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

    func testAcceptsIncreaseConfirmedBySmallDecrease() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(observedAt: Date(timeIntervalSince1970: 1), remainingPercent: 25, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 301), remainingPercent: 31, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 302), remainingPercent: 30, resetsAt: reset)
        ]

        let filtered = UsageReadingValidation.removingImplausibleIncreases(from: samples)

        XCTAssertEqual(filtered.map(\.remainingPercent), [25, 31, 30])
    }

    func testKeepsIncreasePendingWhenFollowingDecreaseIsTooLarge() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(observedAt: Date(timeIntervalSince1970: 1), remainingPercent: 25, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 2), remainingPercent: 40, resetsAt: reset),
            UsageSample(observedAt: Date(timeIntervalSince1970: 3), remainingPercent: 30, resetsAt: reset)
        ]

        let filtered = UsageReadingValidation.removingImplausibleIncreases(from: samples)

        XCTAssertEqual(filtered.map(\.remainingPercent), [25])
    }

    func testAcceptsIncreaseImmediatelyAfterWindowReset() {
        let previousReset = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(observedAt: Date(timeIntervalSince1970: 1), remainingPercent: 2, resetsAt: previousReset),
            UsageSample(
                observedAt: Date(timeIntervalSince1970: 2),
                remainingPercent: 100,
                resetsAt: previousReset.addingTimeInterval(7 * 24 * 60 * 60)
            )
        ]

        let filtered = UsageReadingValidation.removingImplausibleIncreases(from: samples)

        XCTAssertEqual(filtered.map(\.remainingPercent), [2, 100])
    }

    func testCurrentWindowSamplesTolerateResetTimestampDrift() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let samples = [
            UsageSample(
                observedAt: Date(timeIntervalSince1970: 3),
                remainingPercent: 72,
                resetsAt: reset
            ),
            UsageSample(
                observedAt: Date(timeIntervalSince1970: 1),
                remainingPercent: 88,
                resetsAt: reset.addingTimeInterval(-1)
            ),
            UsageSample(
                observedAt: Date(timeIntervalSince1970: 2),
                remainingPercent: 87,
                resetsAt: reset.addingTimeInterval(1)
            ),
            UsageSample(
                observedAt: Date(timeIntervalSince1970: 4),
                remainingPercent: 100,
                resetsAt: reset.addingTimeInterval(7 * 24 * 60 * 60)
            )
        ]

        let current = UsageReadingValidation.samples(samples, matchingReset: reset)

        XCTAssertEqual(current.map(\.remainingPercent), [88, 87, 72])
    }

    func testReturnsEveryObservedWindowNewestFirstIncludingShortWindows() {
        let day: TimeInterval = 24 * 60 * 60
        let currentReset = Date(timeIntervalSince1970: 40 * day)
        let currentStart = currentReset.addingTimeInterval(-7 * day)
        let shortWindowReset = Date(timeIntervalSince1970: 39 * day)
        let olderReset = Date(timeIntervalSince1970: 32 * day)
        let samples = [
            UsageSample(
                observedAt: olderReset.addingTimeInterval(-7 * day),
                remainingPercent: 100,
                resetsAt: olderReset
            ),
            UsageSample(
                observedAt: olderReset.addingTimeInterval(-day),
                remainingPercent: 45,
                resetsAt: olderReset
            ),
            UsageSample(
                observedAt: shortWindowReset.addingTimeInterval(-6.5 * day),
                remainingPercent: 100,
                resetsAt: shortWindowReset.addingTimeInterval(-1)
            ),
            UsageSample(
                observedAt: currentStart.addingTimeInterval(-6 * 60 * 60),
                remainingPercent: 96,
                resetsAt: shortWindowReset
            ),
            UsageSample(
                observedAt: currentStart,
                remainingPercent: 100,
                resetsAt: currentReset
            )
        ]
        let currentWindow = UsageWindow(
            remainingPercent: 100,
            resetsAt: currentReset,
            durationMinutes: 7 * 24 * 60
        )

        let windows = UsageReadingValidation.historicalWindows(
            in: samples,
            before: currentWindow
        )

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].samples.map(\.remainingPercent), [100, 96])
        XCTAssertEqual(windows[0].window.remainingPercent, 96)
        XCTAssertEqual(windows[0].window.resetsAt, shortWindowReset)
        XCTAssertEqual(windows[0].window.durationMinutes, 7 * 24 * 60)
        XCTAssertEqual(windows[0].fetchedAt, currentStart)
        XCTAssertEqual(windows[1].samples.map(\.remainingPercent), [100, 45])
        XCTAssertEqual(windows[1].window.resetsAt, olderReset)
    }

    func testHistoricalUsageWindowsAreEmptyWithoutEarlierHistory() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let currentWindow = UsageWindow(
            remainingPercent: 90,
            resetsAt: reset,
            durationMinutes: 7 * 24 * 60
        )
        let samples = [
            UsageSample(
                observedAt: reset.addingTimeInterval(-60),
                remainingPercent: 90,
                resetsAt: reset
            )
        ]

        XCTAssertTrue(
            UsageReadingValidation.historicalWindows(
                in: samples,
                before: currentWindow
            ).isEmpty
        )
    }
}
