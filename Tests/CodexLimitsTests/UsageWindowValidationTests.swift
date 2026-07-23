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
}
