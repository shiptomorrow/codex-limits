import XCTest
@testable import CodexLimits

final class WeeklyPaceTests: XCTestCase {
    func testEstimatedUsageRemainingUsesWeeklyPaceAndRemainingAllowance() throws {
        let hours = try XCTUnwrap(DailyRuntimeCalculator.estimatedUsageHoursRemaining(
            weeklyPaceHours: 26,
            remainingPercent: 32
        ))

        XCTAssertEqual(hours, 8.32, accuracy: 0.001)
    }

    func testEstimatedUsageRemainingClampsAllowanceAndRequiresWeeklyPace() throws {
        XCTAssertEqual(DailyRuntimeCalculator.estimatedUsageHoursRemaining(
            weeklyPaceHours: 26,
            remainingPercent: -1
        ), 0)
        XCTAssertEqual(DailyRuntimeCalculator.estimatedUsageHoursRemaining(
            weeklyPaceHours: 26,
            remainingPercent: 101
        ), 26)
        XCTAssertNil(DailyRuntimeCalculator.estimatedUsageHoursRemaining(
            weeklyPaceHours: nil,
            remainingPercent: 32
        ))
    }

    func testSuggestedPaceSpreadsBufferedWeeklyPaceAllowanceUntilReset() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let resetsAt = now.addingTimeInterval(2.75 * 86_400)

        let hoursPerDay = try XCTUnwrap(DailyRuntimeCalculator.suggestedDailyUsageHours(
            weeklyPaceHours: 26,
            remainingPercent: 32,
            safetyBuffer: 3,
            resetsAt: resetsAt,
            now: now
        ))

        XCTAssertEqual(hoursPerDay, 26 * 0.29 / 2.75, accuracy: 0.001)
    }

    func testActivityCacheReadsOnlyAppendedSessionEvents() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            fixture.taskStarted(turnID: "turn-1", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(60))
        ])

        let first = try await fixture.load()
        let unchanged = try await fixture.load()
        try fixture.append(fixture.tokenCount(at: start.addingTimeInterval(120)))
        let appended = try await fixture.load()

        XCTAssertEqual(first, [ActivityInterval(
            start: start,
            end: start.addingTimeInterval(60)
        )])
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(appended, [ActivityInterval(
            start: start,
            end: start.addingTimeInterval(120)
        )])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
    }

    func testActivityCacheCountsOnlyMainThreadSessions() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            fixture.sessionMetadata(threadSource: "user"),
            fixture.taskStarted(turnID: "main-turn", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(120))
        ])
        try fixture.write([
            fixture.sessionMetadata(threadSource: "subagent", hasSubagentSource: true),
            fixture.taskStarted(turnID: "subagent-turn", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(540))
        ], to: fixture.subagentSessionURL)

        let intervals = try await fixture.load()

        XCTAssertEqual(intervals, [ActivityInterval(
            start: start,
            end: start.addingTimeInterval(120)
        )])
    }

    func testSubagentSettingAddsConcurrentRuntimeAndRecalculatesCachedPace() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            fixture.sessionMetadata(threadSource: "user"),
            fixture.taskStarted(turnID: "main-turn", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(120))
        ])
        try fixture.write([
            fixture.sessionMetadata(threadSource: "subagent", hasSubagentSource: true),
            fixture.taskEnded(
                turnID: "subagent-turn", start: start,
                end: start.addingTimeInterval(540), type: "task_complete"
            )
        ], to: fixture.subagentSessionURL)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: fixture.now),
            UsageSample(observedAt: fixture.now, remainingPercent: 95, resetsAt: fixture.now)
        ]

        // Reuse the same cache while switching in both directions.
        for includesSubagents in [false, true, false] {
            let activity = try await fixture.load(includesSubagents: includesSubagents)
            let merged = WeeklyPaceCalculator.merged(activity, joiningGapsUpTo: 0)
            let duration = includesSubagents ? 660.0 : 120.0
            XCTAssertEqual(merged.reduce(0) { $0 + $1.duration }, duration)
            let points = WeeklyPaceCalculator.estimateSeries(
                samples: samples, activity: activity, now: fixture.now,
                factorInPauses: false, proratesShortWindows: false
            )
            XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, duration / 3_600 * 20,
                           accuracy: 0.001)
        }
    }

    func testConcurrentSubagentsAddRuntimeButRepeatedRecordsDoNot() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(3_600)
        let main = ActivityInterval(start: start, end: end)
        let first = ActivityInterval(start: start, end: end, subagentID: "first")
        let second = ActivityInterval(start: start, end: end, subagentID: "second")
        let activity = [main, first, first, second]
        let merged = WeeklyPaceCalculator.merged(activity, joiningGapsUpTo: 0)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.duration }, 3 * 3_600)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: end),
            UsageSample(observedAt: end, remainingPercent: 90, resetsAt: end)
        ]
        for factorInPauses in [false, true] {
            let points = WeeklyPaceCalculator.estimateSeries(
                samples: samples, activity: activity, now: end,
                factorInPauses: factorInPauses, proratesShortWindows: false
            )
            XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 30, accuracy: 0.001)
        }
    }

    func testSubagentHeaderSurvivesInheritedParentHistoryAndCacheAppends() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let parentStart = fixture.now.addingTimeInterval(-600)
        let childStart = fixture.now.addingTimeInterval(-300)
        let parentTurn = fixture.taskEnded(
            turnID: "parent", start: parentStart,
            end: fixture.now.addingTimeInterval(-100), type: "task_complete"
        )
        let childTurn = fixture.taskEnded(
            turnID: "child", start: childStart,
            end: fixture.now.addingTimeInterval(-60), type: "task_complete"
        )
        try fixture.write([fixture.sessionMetadata(threadSource: "user"), parentTurn])
        try fixture.write([
            fixture.sessionMetadata(threadSource: "subagent", createdAt: childStart.addingTimeInterval(0.9)),
            fixture.sessionMetadata(threadSource: "user", createdAt: parentStart),
            fixture.taskStarted(turnID: "parent", at: parentStart),
            parentTurn, childTurn
        ], to: fixture.subagentSessionURL)
        for _ in 0 ..< 2 {
            let excluded = try await fixture.load(includesSubagents: false)
            let included = try await fixture.load(includesSubagents: true)
            XCTAssertEqual(excluded.reduce(0) { $0 + $1.duration }, 500)
            XCTAssertEqual(included.reduce(0) { $0 + $1.duration }, 740)
            XCTAssertEqual(included.filter { $0.subagentID != nil }.count, 1)
            let handle = try FileHandle(forWritingTo: fixture.subagentSessionURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((fixture.sessionMetadata(threadSource: "user") + "\n").utf8))
            try handle.close()
        }
    }

    func testInterruptedTurnStopsBeforeLaterActivityInSameSession() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-18_000)
        let resumed = start.addingTimeInterval(14_400)
        try fixture.write([
            fixture.taskStarted(turnID: "interrupted", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(60))
        ])
        let cache = CodexActivityCache(
            sessionsRoot: fixture.sessionsRoot,
            archivedSessionsRoot: nil,
            cacheURL: fixture.cacheURL
        )
        _ = try cache.loadIntervals(since: start, now: fixture.now)
        try fixture.append(fixture.taskEnded(
            turnID: "interrupted", start: start,
            end: start.addingTimeInterval(120), type: "turn_aborted"
        ))
        try fixture.append(fixture.taskStarted(turnID: "resumed", at: resumed))
        try fixture.append(fixture.tokenCount(at: resumed.addingTimeInterval(60)))

        let intervals = try cache.loadIntervals(since: start, now: fixture.now)
        let expected = [
            ActivityInterval(start: start, end: start.addingTimeInterval(120)),
            ActivityInterval(start: resumed, end: resumed.addingTimeInterval(60))
        ]
        XCTAssertEqual(intervals.sorted { $0.start < $1.start }, expected)

        // Simulate a fully parsed old cache that silently dropped the abort.
        var store = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.cacheURL)
        ) as? [String: Any])
        store["version"] = 3
        var files = try XCTUnwrap(store["files"] as? [String: [String: Any]])
        for key in Array(files.keys) {
            var events = try XCTUnwrap(files[key]?["events"] as? [String: Any])
            events["completions"] = []
            files[key]?["events"] = events
        }
        store["files"] = files
        try JSONSerialization.data(withJSONObject: store).write(to: fixture.cacheURL)
        let rebuilt = try cache.loadIntervals(since: start, now: fixture.now)
        XCTAssertEqual(rebuilt.sorted { $0.start < $1.start }, expected)

        let reset = fixture.now.addingTimeInterval(86_400)
        let points = WeeklyPaceCalculator.estimateSeries(
            samples: [
                UsageSample(observedAt: start, remainingPercent: 58, resetsAt: reset),
                UsageSample(observedAt: resumed.addingTimeInterval(60), remainingPercent: 57, resetsAt: reset)
            ],
            activity: rebuilt, now: fixture.now, factorInPauses: false,
            proratesShortWindows: false
        )
        XCTAssertEqual(try XCTUnwrap(points.first).hoursPerWeek, 5, accuracy: 0.001)
    }

    func testActivityCacheExcludesOnlyMeasuredApprovalWaits() async throws {
        for (requiresApproval, output, removesWait) in [
            (true, "Script running with cell ID 2\nWall time 31.0 seconds\nOutput:\n", true),
            (false, "Script running with cell ID 2\nWall time 31.0 seconds\nOutput:\n", false),
            (true, "Unknown execution time", false),
            (true, "Script completed\nWall time 14840.0 seconds\nOutput:\n", false)
        ] {
            let fixture = try ActivityCacheFixture()
            defer { fixture.remove() }
            let start = fixture.now.addingTimeInterval(-15_000)
            let calledAt = start.addingTimeInterval(10)
            let returnedAt = start.addingTimeInterval(14_850)
            let end = start.addingTimeInterval(14_900)
            let input = requiresApproval
                ? #"text(await tools.exec_command({sandbox_permissions:"require_escalated"}));"#
                : #"text(await tools.exec_command({cmd:"build"}));"#
            try fixture.write([
                fixture.taskStarted(turnID: "turn", at: start),
                try fixture.responseItem(at: calledAt, payload: [
                    "type": "custom_tool_call", "call_id": "call", "input": input
                ]),
                try fixture.responseItem(at: returnedAt, payload: [
                    "type": "custom_tool_call_output", "call_id": "call", "output": output
                ]),
                fixture.taskEnded(turnID: "turn", start: start, end: end, type: "task_complete")
            ])
            let cache = CodexActivityCache(sessionsRoot: fixture.sessionsRoot, archivedSessionsRoot: nil, cacheURL: fixture.cacheURL)
            let intervals = try cache.loadIntervals(since: start, now: fixture.now)
            XCTAssertEqual(intervals, removesWait ? [
                ActivityInterval(start: start, end: calledAt),
                ActivityInterval(start: returnedAt.addingTimeInterval(-31), end: end)
            ] : [ActivityInterval(start: start, end: end)])
            XCTAssertEqual(try cache.loadIntervals(since: start, now: fixture.now), intervals)
        }
    }

    func testActivityCacheReplacesEventsWhenSessionIsRewritten() async throws {
        let scenarios = [
            (name: "smaller", prefix: "", oldTail: String(repeating: " ", count: 1_000), newTail: ""),
            (name: "same size", prefix: "", oldTail: "", newTail: ""),
            (name: "changed prefix", prefix: "", oldTail: "", newTail: String(repeating: " ", count: 1_000)),
            (name: "changed suffix", prefix: String(repeating: " ", count: 9_000), oldTail: "", newTail: String(repeating: " ", count: 1_000))
        ]
        for scenario in scenarios {
            let fixture = try ActivityCacheFixture()
            defer { fixture.remove() }
            let oldStart = fixture.now.addingTimeInterval(-600)
            let newStart = fixture.now.addingTimeInterval(-300)
            try fixture.write([
                scenario.prefix,
                fixture.taskStarted(turnID: "turn-1", at: oldStart),
                fixture.tokenCount(at: oldStart.addingTimeInterval(60)),
                scenario.oldTail
            ])
            try FileManager.default.setAttributes(
                [.modificationDate: fixture.now], ofItemAtPath: fixture.sessionURL.path
            )
            _ = try await fixture.load()

            try fixture.write([
                scenario.prefix,
                fixture.taskStarted(turnID: "turn-2", at: newStart),
                fixture.tokenCount(at: newStart.addingTimeInterval(120)),
                scenario.newTail
            ])
            let rebuilt = try await fixture.load()
            let reread = try await fixture.load()
            XCTAssertEqual(rebuilt, [ActivityInterval(
                start: newStart, end: newStart.addingTimeInterval(120)
            )], scenario.name)
            XCTAssertEqual(reread, rebuilt, scenario.name)

            try fixture.append(fixture.tokenCount(at: newStart.addingTimeInterval(180)))
            let appended = try await fixture.load()
            XCTAssertEqual(appended, [ActivityInterval(
                start: newStart, end: newStart.addingTimeInterval(180)
            )], scenario.name)
        }
    }

    func testActivityCacheRebuildsPersistedCorruption() async throws {
        for keepSession in [true, false] {
            let fixture = try ActivityCacheFixture()
            defer { fixture.remove() }
            let start = fixture.now.addingTimeInterval(-600)
            try fixture.write([
                fixture.taskStarted(turnID: "turn-1", at: start),
                fixture.tokenCount(at: start.addingTimeInterval(60))
            ])
            _ = try await fixture.load()
            var store = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.cacheURL)
            ) as? [String: Any])
            store["corruptionMessage"] = "session became smaller"
            try JSONSerialization.data(withJSONObject: store).write(to: fixture.cacheURL)
            if keepSession {
                try fixture.write([
                    fixture.taskStarted(turnID: "turn-2", at: start),
                    fixture.tokenCount(at: start.addingTimeInterval(120))
                ])
            } else {
                try FileManager.default.removeItem(at: fixture.sessionURL)
            }

            let rebuilt = try await fixture.load()
            XCTAssertEqual(rebuilt, keepSession ? [ActivityInterval(
                start: start, end: start.addingTimeInterval(120)
            )] : [])
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.cacheURL)
            ) as? [String: Any])
            XCTAssertNil(saved["corruptionMessage"])
            let reread = try await fixture.load()
            XCTAssertEqual(reread, rebuilt)
        }
    }

    func testActivityCacheReadsArchivedSessionEvents() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            fixture.taskStarted(turnID: "archived-turn", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(180))
        ], to: fixture.archivedSessionURL)

        let intervals = try await fixture.load()

        XCTAssertEqual(intervals, [ActivityInterval(
            start: start,
            end: start.addingTimeInterval(180)
        )])
    }

    func testActivityCacheKeepsActivityWhenSessionMovesToArchive() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            fixture.taskStarted(turnID: "moved-turn", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(240))
        ])
        let active = try await fixture.load()

        try FileManager.default.moveItem(
            at: fixture.sessionURL,
            to: fixture.archivedSessionURL
        )
        let archived = try await fixture.load()

        XCTAssertEqual(archived, active)
    }

    func testActivityCachePrefersActiveCopyOfArchivedSession() async throws {
        let fixture = try ActivityCacheFixture()
        defer { fixture.remove() }
        let start = fixture.now.addingTimeInterval(-600)
        let lines = [
            fixture.taskStarted(turnID: "duplicate-turn", at: start),
            fixture.tokenCount(at: start.addingTimeInterval(300))
        ]
        try fixture.write(lines)
        try fixture.write(lines, to: fixture.archivedSessionURL)

        let intervals = try await fixture.load()

        XCTAssertEqual(intervals, [ActivityInterval(
            start: start,
            end: start.addingTimeInterval(300)
        )])
    }

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
        XCTAssertEqual(estimate.fastModeProportion, 1, accuracy: 0.001)
    }

    func testEstimateRecordsFastModeProportionBetweenUsageUpdates() throws {
        let start = Date(timeIntervalSince1970: 15_000)
        let now = start.addingTimeInterval(1_000)
        let reset = now.addingTimeInterval(86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: now, remainingPercent: 99, resetsAt: reset)
        ]
        let activity = [
            ActivityInterval(start: start, end: start.addingTimeInterval(350)),
            ActivityInterval(
                start: start.addingTimeInterval(350),
                end: start.addingTimeInterval(650),
                isFastMode: true
            ),
            ActivityInterval(start: start.addingTimeInterval(650), end: now)
        ]

        let estimate = try XCTUnwrap(WeeklyPaceCalculator.estimate(
            samples: samples,
            activity: activity,
            now: now,
            sampleTolerance: 90,
            factorInPauses: false
        ))

        XCTAssertFalse(estimate.isFastMode)
        XCTAssertEqual(estimate.fastModeProportion, 0.3, accuracy: 0.001)
    }

    func testStepStrokeUsesHorizontalThenVerticalForMixedMode() {
        let strokes = WeeklyPaceStepStrokeCalculator.strokes(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 100),
            startIsFastMode: false,
            endIsFastMode: true,
            fastModeProportion: 0.7
        )

        XCTAssertEqual(strokes, [
            WeeklyPaceStepStroke(
                points: [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0)],
                isFastMode: false
            ),
            WeeklyPaceStepStroke(
                points: [CGPoint(x: 60, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)],
                isFastMode: true
            )
        ])
    }

    func testStepStrokeCentersFastShareWhenEndpointColorsMatch() {
        let strokes = WeeklyPaceStepStrokeCalculator.strokes(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 50),
            startIsFastMode: false,
            endIsFastMode: false,
            fastModeProportion: 0.3
        )

        XCTAssertEqual(strokes, [
            WeeklyPaceStepStroke(
                points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50)],
                isFastMode: false
            ),
            WeeklyPaceStepStroke(
                points: [CGPoint(x: 35, y: 0), CGPoint(x: 65, y: 0)],
                isFastMode: true
            )
        ])
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
            factorInPauses: false,
            proratesShortWindows: false
        )

        XCTAssertEqual(points.map(\.date), [
            start.addingTimeInterval(1_800),
            start.addingTimeInterval(3_600),
            start.addingTimeInterval(5_400)
        ])
        XCTAssertEqual(points.map(\.hoursPerWeek), [50, 50, 25])
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

    func testEstimateSeriesProratesOldestPartialWindowToTargetRuntime() throws {
        let start = Date(timeIntervalSince1970: 475_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 85, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(64 * 60), remainingPercent: 84, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(73 * 60), remainingPercent: 83, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(74.5 * 60), remainingPercent: 82, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(77.2 * 60), remainingPercent: 81, resetsAt: reset)
        ]
        let now = try XCTUnwrap(samples.last?.observedAt)
        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: [ActivityInterval(start: start, end: now)],
            now: now,
            factorInPauses: false,
            proratesShortWindows: true,
            proratingThreshold: 15 * 60,
            proratingDistance: 30 * 60
        )

        let expectedUsage = 3 + 16.8 / 64
        XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 0.5 * 100 / expectedUsage, accuracy: 0.01)
    }

    func testEstimateSeriesCanDisableProratingForAbsolutelyRawPace() throws {
        let start = Date(timeIntervalSince1970: 480_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 82, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(2.7 * 60), remainingPercent: 81, resetsAt: reset)
        ]
        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: [ActivityInterval(start: start, end: start.addingTimeInterval(2.7 * 60))],
            now: start.addingTimeInterval(2.7 * 60),
            factorInPauses: false,
            proratesShortWindows: false,
            proratingThreshold: 15 * 60,
            proratingDistance: 30 * 60
        )

        XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 4.5, accuracy: 0.01)
    }

    func testEstimateSeriesCanLookBackMultiplePercentagePoints() throws {
        let start = Date(timeIntervalSince1970: 485_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(6 * 60), remainingPercent: 99, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(18 * 60), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(36 * 60), remainingPercent: 97, resetsAt: reset)
        ]
        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: [ActivityInterval(start: start, end: start.addingTimeInterval(36 * 60))],
            now: start.addingTimeInterval(36 * 60),
            factorInPauses: false,
            proratesShortWindows: false,
            percentagePointLookback: 3
        )

        XCTAssertEqual(points.map(\.hoursPerWeek), [10, 15, 20])
    }

    func testEstimateSeriesPartiallyUsesOldestChangeForPercentageLookback() throws {
        let start = Date(timeIntervalSince1970: 487_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(20 * 60), remainingPercent: 98, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(30 * 60), remainingPercent: 97, resetsAt: reset)
        ]
        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: [ActivityInterval(start: start, end: start.addingTimeInterval(30 * 60))],
            now: start.addingTimeInterval(30 * 60),
            factorInPauses: false,
            proratesShortWindows: false,
            percentagePointLookback: 2
        )

        XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 16.667, accuracy: 0.01)
    }

    func testEstimateSeriesDoesNotProrateAtThreshold() throws {
        let start = Date(timeIntervalSince1970: 490_000)
        let reset = start.addingTimeInterval(7 * 86_400)
        let samples = [
            UsageSample(observedAt: start, remainingPercent: 100, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(60 * 60), remainingPercent: 99, resetsAt: reset),
            UsageSample(observedAt: start.addingTimeInterval(75 * 60), remainingPercent: 98, resetsAt: reset)
        ]
        let now = try XCTUnwrap(samples.last?.observedAt)
        let points = WeeklyPaceCalculator.estimateSeries(
            samples: samples,
            activity: [ActivityInterval(start: start, end: now)],
            now: now,
            factorInPauses: false,
            proratesShortWindows: true,
            proratingThreshold: 15 * 60,
            proratingDistance: 30 * 60
        )

        XCTAssertEqual(try XCTUnwrap(points.last).hoursPerWeek, 25, accuracy: 0.01)
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
            factorInPauses: false,
            proratesShortWindows: true,
            proratingThreshold: 60 * 60,
            proratingDistance: 60 * 60
        )

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(
            points.map(\.windowResetsAt),
            [firstReset, secondReset]
        )
        XCTAssertEqual(points[0].hoursPerWeek, 5, accuracy: 0.01)
        XCTAssertEqual(points[1].hoursPerWeek, 50, accuracy: 0.01)
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
            factorInPauses: false,
            proratesShortWindows: false
        )

        XCTAssertEqual(points.map(\.date), [
            start.addingTimeInterval(900),
            start.addingTimeInterval(1_800),
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

private struct ActivityCacheFixture {
    let root: URL
    let sessionsRoot: URL
    let archivedSessionsRoot: URL
    let cacheURL: URL
    let sessionURL: URL
    let subagentSessionURL: URL
    let archivedSessionURL: URL
    let now = Date(timeIntervalSince1970: 1_776_427_200) // 2026-04-17 12:00:00 UTC

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLimitsActivityCache-\(UUID().uuidString)", isDirectory: true)
        sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        archivedSessionsRoot = root.appendingPathComponent("archived_sessions", isDirectory: true)
        cacheURL = root.appendingPathComponent("cache/events.json")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let day = sessionsRoot
            .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let dayName = String(
            format: "%04d-%02d-%02d",
            components.year!,
            components.month!,
            components.day!
        )
        let sessionName = "rollout-\(dayName)T12-00-00-test.jsonl"
        sessionURL = day.appendingPathComponent(sessionName)
        subagentSessionURL = day.appendingPathComponent(
            "rollout-\(dayName)T12-00-01-subagent.jsonl"
        )
        try FileManager.default.createDirectory(
            at: archivedSessionsRoot,
            withIntermediateDirectories: true
        )
        archivedSessionURL = archivedSessionsRoot.appendingPathComponent(sessionName)
    }

    func load(includesSubagents: Bool = false) async throws -> [ActivityInterval] {
        try await CodexActivityReader.loadIntervals(
            since: now.addingTimeInterval(-3_600),
            now: now,
            sessionsRoot: sessionsRoot,
            archivedSessionsRoot: archivedSessionsRoot,
            cacheURL: cacheURL,
            includesSubagents: includesSubagents
        )
    }

    func write(_ lines: [String], to url: URL? = nil) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: url ?? sessionURL, options: .atomic)
    }

    func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: sessionURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func taskStarted(turnID: String, at date: Date) -> String {
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turnID)","started_at":\#(date.timeIntervalSince1970)}}"#
    }

    func taskEnded(turnID: String, start: Date, end: Date, type: String) -> String {
        #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turnID)","started_at":\#(start.timeIntervalSince1970),"completed_at":\#(end.timeIntervalSince1970)}}"#
    }

    func responseItem(at date: Date, payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "response_item", "timestamp": timestamp(date), "payload": payload
        ])
        return String(decoding: data, as: UTF8.self)
    }

    func sessionMetadata(threadSource: String, hasSubagentSource: Bool = false, createdAt: Date? = nil) -> String {
        let source = hasSubagentSource ? #"{"subagent":{"thread_spawn":{}}}"# : #""vscode""#
        let dateField = createdAt.map { #", "timestamp":"\#(timestamp($0))""# } ?? ""
        return #"{"type":"session_meta","payload":{"thread_source":"\#(threadSource)","source":\#(source)\#(dateField)}}"#
    }

    func tokenCount(at date: Date) -> String {
        #"{"timestamp":"\#(timestamp(date))","type":"event_msg","payload":{"type":"token_count"}}"#
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
