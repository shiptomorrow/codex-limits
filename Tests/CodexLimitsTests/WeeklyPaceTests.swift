import XCTest
@testable import CodexLimits

final class WeeklyPaceTests: XCTestCase {
    func testActivityInheritsMostRecentModeForFirstTurnInNewSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        let interval = ActivityInterval(
            start: start,
            end: start.addingTimeInterval(600)
        )

        let split = CodexActivityReader.split(
            interval,
            at: [],
            inheriting: [(
                date: start.addingTimeInterval(-60),
                isFastMode: true
            )]
        )

        XCTAssertEqual(split, [ActivityInterval(
            start: start,
            end: start.addingTimeInterval(600),
            isFastMode: true
        )])
    }

    func testActivityKeepsSessionModeInsteadOfInheritedMode() {
        let start = Date(timeIntervalSince1970: 2_000)
        let interval = ActivityInterval(
            start: start,
            end: start.addingTimeInterval(600)
        )

        let split = CodexActivityReader.split(
            interval,
            at: [(
                date: start.addingTimeInterval(-120),
                isFastMode: false
            )],
            inheriting: [(
                date: start.addingTimeInterval(-60),
                isFastMode: true
            )]
        )

        XCTAssertEqual(split, [interval])
    }

    func testFastModeDoesNotMultiplyObservedAllowanceDecreaseAgain() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let reset = now.addingTimeInterval(86_400)
        let samples = [
            UsageSample(observedAt: now.addingTimeInterval(-3_600), remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: now, remainingPercent: 90, resetsAt: reset)
        ]
        let activity = [ActivityInterval(
            start: now.addingTimeInterval(-3_600),
            end: now,
            isFastMode: true
        )]

        let estimate = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: false
        ))

        XCTAssertEqual(estimate.percentagePointsUsed, 10, accuracy: 0.01)
        XCTAssertEqual(estimate.hoursPerWeek, 10, accuracy: 0.01)
        XCTAssertTrue(estimate.isFastMode)
    }

    func testMergedActivityPreservesFastModeBoundaries() {
        let start = Date(timeIntervalSince1970: 20_000)
        let intervals = [
            ActivityInterval(start: start, end: start.addingTimeInterval(600)),
            ActivityInterval(
                start: start.addingTimeInterval(300),
                end: start.addingTimeInterval(900),
                isFastMode: true
            )
        ]

        let merged = WeeklyPaceCalculator.merged(intervals, joiningGapsUpTo: 0)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0], ActivityInterval(
            start: start,
            end: start.addingTimeInterval(300)
        ))
        XCTAssertEqual(merged[1], ActivityInterval(
            start: start.addingTimeInterval(300),
            end: start.addingTimeInterval(900),
            isFastMode: true
        ))
    }

    func testDailyRuntimeUsesTwoCompletedSevenAMDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 12
        )))
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-52 * 3_600),
                end: now.addingTimeInterval(-50 * 3_600)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-30 * 3_600),
                end: now.addingTimeInterval(-29 * 3_600)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-4 * 3_600),
                end: now
            )
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageCompletedDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(hours, 1.5, accuracy: 0.001)
    }

    func testDailyRuntimeMergesConcurrentThreads() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 12
        )))
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-28 * 3_600),
                end: now.addingTimeInterval(-26 * 3_600)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-27 * 3_600),
                end: now.addingTimeInterval(-25 * 3_600)
            )
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageCompletedDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(hours, 1.5, accuracy: 0.001)
    }

    func testDailyRuntimeIgnoresDaysUnderFiveMinutes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 12
        )))
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-52 * 3_600),
                end: now.addingTimeInterval(-52 * 3_600 + 4 * 60)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-29 * 3_600),
                end: now.addingTimeInterval(-27 * 3_600)
            )
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageCompletedDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(hours, 2, accuracy: 0.001)
    }

    func testDailyRuntimeReturnsNilWhenEveryDayIsUnderFiveMinutes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 12
        )))
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-52 * 3_600),
                end: now.addingTimeInterval(-52 * 3_600 + 4 * 60)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-28 * 3_600),
                end: now.addingTimeInterval(-28 * 3_600 + 2 * 60)
            )
        ]

        XCTAssertNil(DailyRuntimeCalculator.averageCompletedDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))
    }

    func testRecentDailyRuntimeUsesOnlyCurrentDayAfterItExceedsMostRecentUsableDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let olderDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 7
        )))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: olderDay))
        let currentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: previousDay))
        let now = currentDay.addingTimeInterval(5 * 3_600)
        let activity = [
            ActivityInterval(start: olderDay, end: olderDay.addingTimeInterval(3 * 3_600)),
            ActivityInterval(start: previousDay, end: previousDay.addingTimeInterval(1 * 3_600)),
            ActivityInterval(start: currentDay, end: currentDay.addingTimeInterval(2 * 3_600))
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageRecentDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(hours, 2, accuracy: 0.001)
    }

    func testRecentDailyRuntimeKeepsCompletedDaysUntilCurrentExceedsMostRecentDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let olderDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 7
        )))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: olderDay))
        let currentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: previousDay))
        let now = currentDay.addingTimeInterval(5 * 3_600)
        let activity = [
            ActivityInterval(start: olderDay, end: olderDay.addingTimeInterval(3 * 3_600)),
            ActivityInterval(start: previousDay, end: previousDay.addingTimeInterval(1 * 3_600)),
            ActivityInterval(start: currentDay, end: currentDay.addingTimeInterval(30 * 60))
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageRecentDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(hours, 2, accuracy: 0.001)
    }

    func testRecentDailyRuntimeDoesNotSwitchWhenCurrentOnlyExceedsOlderDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let olderDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 22,
            hour: 7
        )))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: olderDay))
        let currentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: previousDay))
        let now = currentDay.addingTimeInterval(5 * 3_600)
        let activity = [
            ActivityInterval(start: olderDay, end: olderDay.addingTimeInterval(1 * 3_600)),
            ActivityInterval(start: previousDay, end: previousDay.addingTimeInterval(4 * 3_600)),
            ActivityInterval(start: currentDay, end: currentDay.addingTimeInterval(2 * 3_600))
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageRecentDayHours(
            activity: activity,
            now: now,
            calendar: calendar
        ))

        XCTAssertEqual(hours, 2.5, accuracy: 0.001)
    }

    func testHistoricalDailyRuntimeUsesPrecedingTwoDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 12
        )))
        let activity = [
            ActivityInterval(
                start: now.addingTimeInterval(-76 * 3_600),
                end: now.addingTimeInterval(-74 * 3_600)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-100 * 3_600),
                end: now.addingTimeInterval(-99 * 3_600)
            ),
            ActivityInterval(
                start: now.addingTimeInterval(-28 * 3_600),
                end: now.addingTimeInterval(-24 * 3_600)
            )
        ]

        let hours = try XCTUnwrap(DailyRuntimeCalculator.averageCompletedDayHours(
            activity: activity,
            now: now,
            calendar: calendar,
            dayOffset: 2
        ))

        XCTAssertEqual(hours, 1.5, accuracy: 0.001)
    }

    func testHistoricalDailyRuntimeUsesActiveDayInterquartileMeanFromPreviousTwoWeeks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 24,
            hour: 12
        )))
        let currentDayStart = try XCTUnwrap(calendar.date(
            bySettingHour: DailyRuntimeCalculator.dayStartHour,
            minute: 0,
            second: 0,
            of: now
        ))
        let activeHours = [0.241, 0.601, 1.007, 3.606, 4.591, 5.757]
        var activity = try activeHours.enumerated().map { index, hours in
            let start = try XCTUnwrap(calendar.date(
                byAdding: .day,
                value: -(index + 1),
                to: currentDayStart
            ))
            return ActivityInterval(
                start: start,
                end: start.addingTimeInterval(hours * 3_600)
            )
        }
        let belowMinimumStart = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -7,
            to: currentDayStart
        ))
        activity.append(ActivityInterval(
            start: belowMinimumStart,
            end: belowMinimumStart.addingTimeInterval(4 * 60)
        ))
        activity.append(ActivityInterval(
            start: currentDayStart,
            end: currentDayStart.addingTimeInterval(8 * 3_600)
        ))
        let tooOldStart = try XCTUnwrap(calendar.date(
            byAdding: .day,
            value: -15,
            to: currentDayStart
        ))
        activity.append(ActivityInterval(
            start: tooOldStart,
            end: tooOldStart.addingTimeInterval(10 * 3_600)
        ))

        let hours = try XCTUnwrap(
            DailyRuntimeCalculator.interquartileMeanCompletedDayHours(
                activity: activity,
                now: now,
                calendar: calendar
            )
        )

        XCTAssertEqual(hours, 2.45125, accuracy: 0.0001)
    }

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

        XCTAssertEqual(points.map(\.date), [
            start.addingTimeInterval(1_800),
            start.addingTimeInterval(2_700),
            start.addingTimeInterval(3_600),
            start.addingTimeInterval(4_500),
            start.addingTimeInterval(5_400)
        ])
        XCTAssertEqual(try XCTUnwrap(points.first).hoursPerWeek, 50, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 33.333, accuracy: 0.01)
    }

    func testEstimateUsesChangeEventsWithoutMinuteBoundarySamples() throws {
        let start = Date(timeIntervalSince1970: 450_000)
        let now = start.addingTimeInterval(600)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: reset),
            UsageSample(
                observedAt: start.addingTimeInterval(300),
                remainingPercent: 99,
                resetsAt: reset
            )
        ]
        let activity = [ActivityInterval(start: start, end: now)]

        let estimate = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: false
        ))

        XCTAssertEqual(estimate.activeDuration, 600, accuracy: 0.01)
        XCTAssertEqual(estimate.percentagePointsUsed, 1, accuracy: 0.01)
        XCTAssertEqual(estimate.hoursPerWeek, 16.667, accuracy: 0.01)
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

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(
            points.map(\.windowResetsAt),
            [firstReset, firstReset, firstReset, secondReset]
        )
        XCTAssertEqual(points[0].hoursPerWeek, 5, accuracy: 0.01)
        XCTAssertEqual(points[3].hoursPerWeek, 50, accuracy: 0.01)
    }

    func testEstimateSeriesToleratesSmallResetTimeDrift() {
        let start = Date(timeIntervalSince1970: 650_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let driftedReset = reset.addingTimeInterval(1)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: driftedReset),
            UsageSample(observedAt: start.addingTimeInterval(900), remainingPercent: 99, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(1_800), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(3_600), remainingPercent: 96, resetsAt: driftedReset),
            UsageSample(observedAt: start.addingTimeInterval(4_500), remainingPercent: 95, resetsAt: reset)
        ]
        let activity = [ActivityInterval(start: start, end: start.addingTimeInterval(4_500))]

        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: activity,
            now: start.addingTimeInterval(4_500),
            sampleTolerance: 90,
            factorInPauses: false
        )

        XCTAssertEqual(points.map(\.date), [
            start.addingTimeInterval(900),
            start.addingTimeInterval(1_800),
            start.addingTimeInterval(2_700),
            start.addingTimeInterval(3_600),
            start.addingTimeInterval(4_500)
        ])
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

    func testStabilizedSeriesSuppressesIsolatedOutlier() {
        let start = Date(timeIntervalSince1970: 250_000)
        let reset = start.addingTimeInterval(86_400)
        let points = [6.3, 6.2, 9.8, 5.9].enumerated().map { index, hours in
            WeeklyPacePoint(
                date: start.addingTimeInterval(Double(index) * 900),
                hoursPerWeek: hours,
                windowResetsAt: reset
            )
        }

        let stabilized = WeeklyPaceCalculator.stabilizedSeries(points)

        XCTAssertEqual(stabilized.map(\.hoursPerWeek), [6.3, 6.2, 6.3, 5.9])
    }

    func testStabilizedSeriesShowsSustainedPaceChangeAfterOnePoint() {
        let start = Date(timeIntervalSince1970: 275_000)
        let reset = start.addingTimeInterval(86_400)
        let points = [6.3, 6.2, 9.8, 10.1, 9.9].enumerated().map { index, hours in
            WeeklyPacePoint(
                date: start.addingTimeInterval(Double(index) * 900),
                hoursPerWeek: hours,
                windowResetsAt: reset
            )
        }

        let stabilized = WeeklyPaceCalculator.stabilizedSeries(points)

        XCTAssertEqual(stabilized.map(\.hoursPerWeek), [6.3, 6.2, 6.3, 10.1, 9.9])
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
