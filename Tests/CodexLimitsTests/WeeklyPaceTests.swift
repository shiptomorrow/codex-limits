import XCTest
@testable import CodexLimits

final class WeeklyPaceTests: XCTestCase {
    func testCompressedTimelineCapsLongGapsAtOneHour() {
        let start = Date(timeIntervalSince1970: 700_000)
        let nearby = start.addingTimeInterval(30 * 60)
        let afterLongGap = nearby.addingTimeInterval(12 * 60 * 60)
        let timeline = WeeklyPaceCompressedTimeline(
            dates: [start, nearby, afterLongGap]
        )

        XCTAssertEqual(timeline.position(for: start), 0, accuracy: 0.01)
        XCTAssertEqual(timeline.position(for: nearby), 30 * 60, accuracy: 0.01)
        XCTAssertEqual(timeline.position(for: afterLongGap), 90 * 60, accuracy: 0.01)
        XCTAssertEqual(
            timeline.date(at: 60 * 60).timeIntervalSince(nearby),
            6 * 60 * 60,
            accuracy: 0.01
        )
    }

    func testCompressedTimelineKeepsResetTransitionClose() {
        let previous = Date(timeIntervalSince1970: 800_000)
        let current = previous.addingTimeInterval(24 * 60 * 60)
        let timeline = WeeklyPaceCompressedTimeline(
            dates: [previous, current],
            resetTransition: WeeklyPaceResetTransition(
                previousDate: previous,
                currentDate: current
            )
        )

        XCTAssertEqual(timeline.position(for: previous), 0, accuracy: 0.01)
        XCTAssertEqual(timeline.position(for: current), 5 * 60, accuracy: 0.01)
    }

    func testEstimateUsesConfiguredLookback() throws {
        let now = Date(timeIntervalSince1970: 500_000)
        let reset = now.addingTimeInterval(86_400)
        let samples = [
            UsageSample(observedAt: now.addingTimeInterval(-7_200), remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-3_600), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: now, remainingPercent: 88, resetsAt: reset)
        ]
        let activity = [ActivityInterval(start: now.addingTimeInterval(-7_200), end: now)]

        let oneHour = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: false,
            lookback: 3_600
        ))
        let twoHours = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: false,
            lookback: 7_200
        ))

        XCTAssertEqual(oneHour.hoursPerWeek, 10, accuracy: 0.01)
        XCTAssertEqual(twoHours.hoursPerWeek, 16.667, accuracy: 0.01)
    }

    func testEstimateSeriesTracksPaceChangesFromUsageHistory() throws {
        let start = Date(timeIntervalSince1970: 400_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(1_800), remainingPercent: 99, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(3_600), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(5_400), remainingPercent: 96, resetsAt: reset)
        ]
        let activity = [ActivityInterval(start: start, end: start.addingTimeInterval(5_400))]

        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: activity,
            now: start.addingTimeInterval(5_400),
            sampleTolerance: 90,
            factorInPauses: false
        )

        XCTAssertEqual(points.map(\.date), Array(samples.dropFirst()).map(\.observedAt))
        XCTAssertEqual(try XCTUnwrap(points.first).hoursPerWeek, 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 33.333, accuracy: 0.01)
    }

    func testEstimateSeriesKeepsUsageWindowsIndependent() throws {
        let start = Date(timeIntervalSince1970: 600_000)
        let firstReset = start.addingTimeInterval(3_600)
        let secondReset = firstReset.addingTimeInterval(3_600)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: firstReset),
            UsageSample(observedAt: start.addingTimeInterval(1_800), remainingPercent: 90, resetsAt: firstReset),
            UsageSample(observedAt: firstReset, remainingPercent: 100, resetsAt: secondReset),
            UsageSample(observedAt: firstReset.addingTimeInterval(1_800), remainingPercent: 99, resetsAt: secondReset)
        ]
        let activity = [
            ActivityInterval(start: start, end: firstReset.addingTimeInterval(1_800))
        ]

        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: activity,
            now: firstReset.addingTimeInterval(1_800),
            sampleTolerance: 90,
            factorInPauses: false
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.map(\.windowResetsAt), [firstReset, secondReset])
        XCTAssertEqual(points[0].hoursPerWeek, 5, accuracy: 0.01)
        XCTAssertEqual(points[1].hoursPerWeek, 50, accuracy: 0.01)
    }

    func testExcludesIdleGapLongerThanFifteenMinutes() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let reset = now.addingTimeInterval(86_400)
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-3_600),
                end: now.addingTimeInterval(-3_000)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-600),
                end: now
            )
        ]
        let samples = [
            UsageSample(observedAt: now.addingTimeInterval(-3_600), remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-3_000), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-600), remainingPercent: 97, resetsAt: reset),
            UsageSample(observedAt: now, remainingPercent: 95, resetsAt: reset)
        ]

        let estimate = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: true
        ))

        XCTAssertEqual(estimate.activeDuration, 1_200, accuracy: 0.01)
        XCTAssertEqual(estimate.percentagePointsUsed, 4, accuracy: 0.01)
        XCTAssertEqual(estimate.hoursPerWeek, 8.333, accuracy: 0.01)
    }

    func testShortRecentSessionIncludesPreviousActiveHour() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let reset = now.addingTimeInterval(86_400)
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-7_200),
                end: now.addingTimeInterval(-3_600)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-300),
                end: now
            )
        ]
        let samples = [
            UsageSample(observedAt: now.addingTimeInterval(-7_200), remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-3_600), remainingPercent: 90, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-300), remainingPercent: 89, resetsAt: reset),
            UsageSample(observedAt: now, remainingPercent: 88, resetsAt: reset)
        ]

        let estimate = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: true
        ))

        XCTAssertEqual(estimate.activeDuration, 3_900, accuracy: 0.01)
        XCTAssertEqual(estimate.percentagePointsUsed, 11, accuracy: 0.01)
        XCTAssertEqual(estimate.hoursPerWeek, 9.848, accuracy: 0.01)
    }

    func testCanExcludeEveryIdleSecond() throws {
        let now = Date(timeIntervalSince1970: 300_000)
        let reset = now.addingTimeInterval(86_400)
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-1_800),
                end: now.addingTimeInterval(-1_500)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-900),
                end: now.addingTimeInterval(-600)
            )
        ]
        let samples = [
            UsageSample(observedAt: now.addingTimeInterval(-1_800), remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-1_500), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-900), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: now.addingTimeInterval(-600), remainingPercent: 96, resetsAt: reset)
        ]

        let withPauses = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now.addingTimeInterval(-600),
            sampleTolerance: 90,
            factorInPauses: true
        ))
        let withoutPauses = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now.addingTimeInterval(-600),
            sampleTolerance: 90,
            factorInPauses: false
        ))

        XCTAssertEqual(withPauses.activeDuration, 1_200, accuracy: 0.01)
        XCTAssertEqual(withoutPauses.activeDuration, 600, accuracy: 0.01)
        XCTAssertEqual(withPauses.hoursPerWeek, 8.333, accuracy: 0.01)
        XCTAssertEqual(withoutPauses.hoursPerWeek, 4.167, accuracy: 0.01)
    }
}
