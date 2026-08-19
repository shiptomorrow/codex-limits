import Foundation

struct ActivityInterval: Equatable, Sendable {
    let start: Date
    let end: Date
    var isFastMode = false

    var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

struct WeeklyPaceEstimate: Equatable, Sendable {
    let hoursPerWeek: Double
    let activeDuration: TimeInterval
    let percentagePointsUsed: Double
    let isFastMode: Bool
    let fastModeProportion: Double
}

struct WeeklyPacePoint: Equatable, Identifiable, Sendable {
    let date: Date
    let hoursPerWeek: Double
    let windowResetsAt: Date
    var isFastMode: Bool
    var isUsageChange: Bool
    var fastModeProportion: Double

    init(
        date: Date,
        hoursPerWeek: Double,
        windowResetsAt: Date,
        isFastMode: Bool = false,
        isUsageChange: Bool = false,
        fastModeProportion: Double? = nil
    ) {
        self.date = date
        self.hoursPerWeek = hoursPerWeek
        self.windowResetsAt = windowResetsAt
        self.isFastMode = isFastMode
        self.isUsageChange = isUsageChange
        self.fastModeProportion = min(max(
            fastModeProportion ?? (isFastMode ? 1 : 0),
            0
        ), 1)
    }

    var id: Date { date }
}

enum DailyRuntimeCalculator {
    static let dayStartHour = 7
    static let completedDayCount = 2
    static let historicalDayCount = 14
    static let minimumIncludedDayHours = 5.0 / 60

    static func estimatedUsageHoursRemaining(
        weeklyPaceHours: Double?,
        remainingPercent: Double
    ) -> Double? {
        guard let weeklyPaceHours,
              weeklyPaceHours.isFinite,
              weeklyPaceHours >= 0,
              remainingPercent.isFinite else {
            return nil
        }
        let availablePercent = min(max(remainingPercent, 0), 100)
        return weeklyPaceHours * availablePercent / 100
    }

    static func suggestedDailyUsageHours(
        weeklyPaceHours: Double?,
        remainingPercent: Double,
        safetyBuffer: Double,
        resetsAt: Date,
        now: Date
    ) -> Double? {
        guard safetyBuffer.isFinite,
              let usableHours = estimatedUsageHoursRemaining(
                  weeklyPaceHours: weeklyPaceHours,
                  remainingPercent: remainingPercent - max(safetyBuffer, 0)
              ) else {
            return nil
        }
        let daysRemaining = max(resetsAt.timeIntervalSince(now), 0) / 86_400
        guard daysRemaining > 0 else { return 0 }
        return usableHours / daysRemaining
    }

    static func averageRecentDayHours(
        activity: [ActivityInterval],
        now: Date,
        calendar: Calendar = .current
    ) -> Double? {
        guard let windows = completedDayWindows(
            now: now,
            calendar: calendar,
            dayCount: completedDayCount
        ), windows.count == completedDayCount,
           let currentDayStart = windows.last?.end else {
            return nil
        }

        let completedHours = windows.map {
            hours(activity: activity, from: $0.start, to: $0.end)
        }.filter(isIncludedDay)
        let currentHours = hours(activity: activity, from: currentDayStart, to: now)
        guard !completedHours.isEmpty else {
            return isIncludedDay(currentHours) ? currentHours : nil
        }
        if let lastCompletedHours = completedHours.last,
           isIncludedDay(currentHours),
           currentHours > lastCompletedHours {
            return currentHours
        }
        return completedHours.reduce(0, +) / Double(completedHours.count)
    }

    static func averageCompletedDayHours(
        activity: [ActivityInterval],
        now: Date,
        calendar: Calendar = .current,
        dayOffset: Int = 0,
        dayCount: Int = completedDayCount
    ) -> Double? {
        guard let windows = completedDayWindows(
            now: now,
            calendar: calendar,
            dayOffset: dayOffset,
            dayCount: dayCount
        ) else {
            return nil
        }
        let includedHours = windows.map { window in
            hours(activity: activity, from: window.start, to: window.end)
        }.filter(isIncludedDay)
        guard !includedHours.isEmpty else {
            return nil
        }
        return includedHours.reduce(0, +) / Double(includedHours.count)
    }

    static func interquartileMeanCompletedDayHours(
        activity: [ActivityInterval],
        now: Date,
        calendar: Calendar = .current,
        dayCount: Int = historicalDayCount
    ) -> Double? {
        guard let windows = completedDayWindows(
            now: now,
            calendar: calendar,
            dayCount: dayCount
        ) else {
            return nil
        }
        let includedHours = windows.map { window in
            hours(activity: activity, from: window.start, to: window.end)
        }
        .filter(isIncludedDay)
        .sorted()
        guard !includedHours.isEmpty else {
            return nil
        }

        let trimCount = includedHours.count / 4
        let interquartileHours = includedHours[
            trimCount ..< (includedHours.count - trimCount)
        ]
        return interquartileHours.reduce(0, +) / Double(interquartileHours.count)
    }

    static func completedDayWindows(
        now: Date,
        calendar: Calendar = .current,
        dayOffset: Int = 0,
        dayCount: Int = completedDayCount
    ) -> [(start: Date, end: Date)]? {
        guard dayOffset >= 0, dayCount > 0 else { return nil }
        guard var currentStart = calendar.date(
            bySettingHour: dayStartHour,
            minute: 0,
            second: 0,
            of: now
        ) else {
            return nil
        }
        if now < currentStart {
            guard let previousStart = calendar.date(
                byAdding: .day,
                value: -1,
                to: currentStart
            ) else {
                return nil
            }
            currentStart = previousStart
        }

        var windows: [(start: Date, end: Date)] = []
        var end = currentStart
        for _ in 0 ..< dayOffset {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: end) else {
                return nil
            }
            end = previous
        }
        for _ in 0 ..< dayCount {
            guard let start = calendar.date(byAdding: .day, value: -1, to: end) else {
                return nil
            }
            windows.append((start: start, end: end))
            end = start
        }
        return Array(windows.reversed())
    }

    private static func hours(
        activity: [ActivityInterval],
        from windowStart: Date,
        to windowEnd: Date
    ) -> Double {
        let clipped = activity.compactMap { interval -> ActivityInterval? in
            let start = max(interval.start, windowStart)
            let end = min(interval.end, windowEnd)
            guard end > start else { return nil }
            return ActivityInterval(start: start, end: end)
        }
        let merged = WeeklyPaceCalculator.merged(clipped, joiningGapsUpTo: 0)
        return merged.reduce(0) { $0 + $1.duration } / 3_600
    }

    private static func isIncludedDay(_ hours: Double) -> Bool {
        hours >= minimumIncludedDayHours
    }
}

enum WeeklyPaceCalculator {
    static let idleGap: TimeInterval = 15 * 60
    private static let resetTimeTolerance: TimeInterval = 5 * 60
    private static let recentSessionMinimum: TimeInterval = 15 * 60
    private static let maximumActiveLookback: TimeInterval = 3 * 60 * 60

    static func estimate(
        samples: [UsageSample],
        activity rawActivity: [ActivityInterval],
        now: Date,
        sampleTolerance: TimeInterval,
        factorInPauses: Bool,
        lookback: TimeInterval = 60 * 60
    ) -> WeeklyPaceEstimate? {
        let samples = samples.sorted { $0.observedAt < $1.observedAt }
        guard samples.count > 1 else { return nil }
        let lookback = min(max(lookback, 15 * 60), maximumActiveLookback)

        let includedPause = factorInPauses ? idleGap : 0
        var blocks = merged(rawActivity, joiningGapsUpTo: includedPause)
            .compactMap {
                intersection($0, with: samples[0].observedAt ... now)
            }
        guard !blocks.isEmpty else { return nil }

        if let last = blocks.last, now.timeIntervalSince(last.end) <= idleGap {
            blocks[blocks.count - 1] = ActivityInterval(
                start: last.start,
                end: now,
                isFastMode: last.isFastMode
            )
        }

        var selected: [ActivityInterval]
        if let last = blocks.last,
           now.timeIntervalSince(last.end) <= idleGap,
           last.duration < recentSessionMinimum {
            selected = [last]
            selected += previousActivity(
                before: last.start,
                from: blocks.dropLast(),
                duration: lookback
            )
        } else {
            let lookbackStart = now.addingTimeInterval(-lookback)
            selected = blocks.compactMap { intersection($0, with: lookbackStart ... now) }
        }

        guard !selected.isEmpty else { return nil }
        selected = merged(selected, joiningGapsUpTo: includedPause)

        var measured = measurement(
            samples: samples,
            intervals: selected,
            tolerance: sampleTolerance
        )

        // Whole-percentage readings can be noisy over a short burst. Extend backward
        // through prior active blocks until at least two points are observed.
        if measured.used < 2, measured.duration < maximumActiveLookback,
           let earliest = selected.map(\.start).min() {
            for block in blocks.filter({ $0.end < earliest }).reversed() {
                selected.append(block)
                selected = merged(selected, joiningGapsUpTo: includedPause)
                measured = measurement(
                    samples: samples,
                    intervals: selected,
                    tolerance: sampleTolerance
                )
                if measured.used >= 2 || measured.duration >= maximumActiveLookback {
                    break
                }
            }
        }

        guard measured.used > 0, measured.duration > 0 else { return nil }
        let usedPerActiveHour = measured.used / (measured.duration / 3_600)
        guard usedPerActiveHour.isFinite, usedPerActiveHour > 0 else { return nil }
        let modeBreakdown = latestUsageModeBreakdown(
            samples: samples,
            intervals: merged(rawActivity, joiningGapsUpTo: 0),
            tolerance: sampleTolerance
        )

        return WeeklyPaceEstimate(
            hoursPerWeek: 100 / usedPerActiveHour,
            activeDuration: measured.duration,
            percentagePointsUsed: measured.used,
            isFastMode: modeBreakdown?.isFastMode ?? measured.isFastMode,
            fastModeProportion: modeBreakdown?.fastModeProportion
                ?? measured.fastModeProportion
        )
    }

    static func estimateSeries(
        samples rawSamples: [UsageSample],
        activity: [ActivityInterval],
        now: Date,
        factorInPauses: Bool,
        proratesShortWindows: Bool = true,
        proratingThreshold: TimeInterval = 15 * 60,
        proratingDistance: TimeInterval = 30 * 60,
        percentagePointLookback: Int = 1
    ) -> [WeeklyPacePoint] {
        let samples = rawSamples
            .filter { $0.observedAt <= now }
            .sorted { $0.observedAt < $1.observedAt }
        let windows = samples.reduce(into: [[UsageSample]]()) { windows, sample in
            if let index = windows.firstIndex(where: { window in
                guard let reset = window.first?.resetsAt else { return false }
                return abs(reset.timeIntervalSince(sample.resetsAt)) <= resetTimeTolerance
            }) {
                windows[index].append(sample)
            } else {
                windows.append([sample])
            }
        }

        let includedPause = factorInPauses ? idleGap : 0
        let activity = merged(activity, joiningGapsUpTo: includedPause)
        let threshold = max(proratingThreshold, 0)
        let distance = max(proratingDistance, threshold)
        let percentagePointLookback = Double(max(percentagePointLookback, 1))

        return windows.flatMap { windowSamples in
            usageChangePoints(
                samples: windowSamples,
                activity: activity,
                proratesShortWindows: proratesShortWindows,
                proratingThreshold: threshold,
                proratingDistance: distance,
                percentagePointLookback: percentagePointLookback
            )
        }
        .sorted { $0.date < $1.date }
    }

    private struct UsageChangeMeasurement {
        let sample: UsageSample
        let percentagePointsUsed: Double
        let activeDuration: TimeInterval
        let isFastMode: Bool
        let fastModeProportion: Double
    }

    private static func usageChangePoints(
        samples: [UsageSample],
        activity: [ActivityInterval],
        proratesShortWindows: Bool,
        proratingThreshold: TimeInterval,
        proratingDistance: TimeInterval,
        percentagePointLookback: Double
    ) -> [WeeklyPacePoint] {
        let samples = samples.sorted { $0.observedAt < $1.observedAt }
        guard samples.count > 1 else { return [] }

        let measurements = samples.indices.dropFirst().compactMap { index -> UsageChangeMeasurement? in
            let previous = samples[index - 1]
            let current = samples[index]
            let decrease = previous.remainingPercent - current.remainingPercent
            guard decrease > 0 else { return nil }

            let intervals = activity.compactMap {
                intersection($0, with: previous.observedAt ... current.observedAt)
            }
            let duration = intervals.reduce(0) { $0 + $1.duration }
            guard duration > 0 else { return nil }
            let fastDuration = intervals
                .filter(\.isFastMode)
                .reduce(0) { $0 + $1.duration }

            return UsageChangeMeasurement(
                sample: current,
                percentagePointsUsed: decrease,
                activeDuration: duration,
                isFastMode: intervals.last?.isFastMode == true,
                fastModeProportion: min(max(fastDuration / duration, 0), 1)
            )
        }

        return measurements.indices.map { index in
            let current = measurements[index]
            var duration = current.activeDuration
            var used = current.percentagePointsUsed
            var includedFractions = [index: 1.0]

            if used < percentagePointLookback {
                for priorIndex in measurements.indices[..<index].reversed()
                    where used < percentagePointLookback {
                    let prior = measurements[priorIndex]
                    let includedUsage = min(
                        prior.percentagePointsUsed,
                        percentagePointLookback - used
                    )
                    let includedFraction = includedUsage / prior.percentagePointsUsed
                    duration += prior.activeDuration * includedFraction
                    used += includedUsage
                    includedFractions[priorIndex] = includedFraction
                }
            }

            if proratesShortWindows,
               duration < proratingThreshold,
               duration < proratingDistance {
                var remainingDuration = proratingDistance - duration
                for priorIndex in measurements.indices[..<index].reversed()
                    where remainingDuration > 0 {
                    let prior = measurements[priorIndex]
                    let availableFraction = 1 - (includedFractions[priorIndex] ?? 0)
                    let availableDuration = prior.activeDuration * availableFraction
                    let includedDuration = min(availableDuration, remainingDuration)
                    duration += includedDuration
                    used += prior.percentagePointsUsed
                        * includedDuration / prior.activeDuration
                    remainingDuration -= includedDuration
                }
            }

            return WeeklyPacePoint(
                date: current.sample.observedAt,
                hoursPerWeek: duration / 3_600 * 100 / used,
                windowResetsAt: current.sample.resetsAt,
                isFastMode: current.isFastMode,
                isUsageChange: true,
                fastModeProportion: current.fastModeProportion
            )
        }
    }

    static func merged(
        _ intervals: [ActivityInterval],
        joiningGapsUpTo allowedGap: TimeInterval
    ) -> [ActivityInterval] {
        let intervals = intervals.filter { $0.end > $0.start }
        let boundaries = Set(intervals.flatMap { [$0.start, $0.end] }).sorted()
        let slices = boundaries.indices.dropLast().compactMap { index -> ActivityInterval? in
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let active = intervals.filter { $0.start < end && $0.end > start }
            guard !active.isEmpty else { return nil }
            return ActivityInterval(
                start: start,
                end: end,
                isFastMode: active.contains(where: \.isFastMode)
            )
        }

        return slices.reduce(into: []) { result, interval in
            guard let last = result.last else {
                result.append(interval)
                return
            }
            if interval.isFastMode == last.isFastMode,
               interval.start.timeIntervalSince(last.end) <= allowedGap {
                result[result.count - 1] = ActivityInterval(
                    start: last.start,
                    end: max(last.end, interval.end),
                    isFastMode: last.isFastMode
                )
            } else {
                result.append(interval)
            }
        }
    }

    private static func previousActivity(
        before date: Date,
        from blocks: ArraySlice<ActivityInterval>,
        duration target: TimeInterval
    ) -> [ActivityInterval] {
        var result: [ActivityInterval] = []
        var remaining = target

        for block in blocks.filter({ $0.end <= date }).reversed() where remaining > 0 {
            let included = min(block.duration, remaining)
            result.append(ActivityInterval(
                start: block.end.addingTimeInterval(-included),
                end: block.end,
                isFastMode: block.isFastMode
            ))
            remaining -= included
        }
        return result
    }

    private static func intersection(
        _ interval: ActivityInterval,
        with range: ClosedRange<Date>
    ) -> ActivityInterval? {
        let start = max(interval.start, range.lowerBound)
        let end = min(interval.end, range.upperBound)
        guard end > start else { return nil }
        return ActivityInterval(
            start: start,
            end: end,
            isFastMode: interval.isFastMode
        )
    }

    private static func measurement(
        samples: [UsageSample],
        intervals: [ActivityInterval],
        tolerance: TimeInterval
    ) -> (used: Double, duration: TimeInterval, isFastMode: Bool, fastModeProportion: Double) {
        let duration = intervals.reduce(0) { $0 + $1.duration }
        var latestUsageWasFast = false
        var latestFastModeProportion = 0.0
        let used = samples.indices.dropFirst().reduce(0.0) { total, index in
            let previous = samples[index - 1]
            let current = samples[index]
            let decrease = max(previous.remainingPercent - current.remainingPercent, 0)
            guard decrease > 0 else { return total }

            let matchingIntervals = intervals.filter { interval in
                current.observedAt > interval.start
                    && current.observedAt <= interval.end.addingTimeInterval(tolerance)
                    && previous.observedAt <= interval.end
            }
            guard !matchingIntervals.isEmpty else { return total }
            let isFastMode = matchingIntervals.last?.isFastMode == true
            latestUsageWasFast = isFastMode
            let activityBetweenUpdates = matchingIntervals.compactMap {
                intersection(
                    $0,
                    with: previous.observedAt ... current.observedAt
                )
            }
            let updateDuration = activityBetweenUpdates.reduce(0) { $0 + $1.duration }
            let fastDuration = activityBetweenUpdates
                .filter(\.isFastMode)
                .reduce(0) { $0 + $1.duration }
            latestFastModeProportion = updateDuration > 0
                ? min(max(fastDuration / updateDuration, 0), 1)
                : (isFastMode ? 1 : 0)
            // The observed allowance decrease already includes any fast-mode cost.
            return total + decrease
        }

        return (used, duration, latestUsageWasFast, latestFastModeProportion)
    }

    private static func latestUsageModeBreakdown(
        samples: [UsageSample],
        intervals: [ActivityInterval],
        tolerance: TimeInterval
    ) -> (isFastMode: Bool, fastModeProportion: Double)? {
        for index in samples.indices.dropFirst().reversed() {
            let previous = samples[index - 1]
            let current = samples[index]
            guard previous.remainingPercent > current.remainingPercent else { continue }
            let matchingIntervals = intervals.filter { interval in
                current.observedAt > interval.start
                    && current.observedAt <= interval.end.addingTimeInterval(tolerance)
                    && previous.observedAt <= interval.end
            }
            guard !matchingIntervals.isEmpty else { continue }
            let activityBetweenUpdates = matchingIntervals.compactMap {
                intersection($0, with: previous.observedAt ... current.observedAt)
            }
            let duration = activityBetweenUpdates.reduce(0) { $0 + $1.duration }
            guard duration > 0 else { continue }
            let fastDuration = activityBetweenUpdates
                .filter(\.isFastMode)
                .reduce(0) { $0 + $1.duration }
            return (
                isFastMode: activityBetweenUpdates.last?.isFastMode == true,
                fastModeProportion: min(max(fastDuration / duration, 0), 1)
            )
        }
        return nil
    }
}

enum CodexActivityReader {
    static func loadIntervals(since: Date, now: Date) async throws -> [ActivityInterval] {
        let codexRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let sessionsRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let archivedSessionsRoot = codexRoot.appendingPathComponent(
            "archived_sessions",
            isDirectory: true
        )
        let cache = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent("ActivityCache", isDirectory: true)
            .appendingPathComponent("events-v2.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("codex-limits-events-v2.json")
        return try await loadIntervals(
            since: since,
            now: now,
            sessionsRoot: sessionsRoot,
            archivedSessionsRoot: archivedSessionsRoot,
            cacheURL: cache
        )
    }

    static func loadIntervals(
        since: Date,
        now: Date,
        sessionsRoot: URL,
        archivedSessionsRoot: URL? = nil,
        cacheURL: URL
    ) async throws -> [ActivityInterval] {
        try await Task.detached(priority: .utility) {
            try CodexActivityCache(
                sessionsRoot: sessionsRoot,
                archivedSessionsRoot: archivedSessionsRoot,
                cacheURL: cacheURL
            )
                .loadIntervals(since: since, now: now)
        }.value
    }

    static func split(
        _ interval: ActivityInterval,
        at rawChanges: [(date: Date, isFastMode: Bool)],
        inheriting inheritedChanges: [(date: Date, isFastMode: Bool)] = []
    ) -> [ActivityInterval] {
        let changes = rawChanges.sorted { $0.date < $1.date }
        let inheritedMode = inheritedChanges
            .filter { $0.date <= interval.start }
            .max(by: { $0.date < $1.date })?
            .isFastMode
        var isFastMode = changes.last(where: { $0.date <= interval.start })?.isFastMode
            ?? inheritedMode
            ?? false
        var start = interval.start
        var result: [ActivityInterval] = []

        for change in changes where change.date > interval.start && change.date < interval.end {
            result.append(ActivityInterval(
                start: start,
                end: change.date,
                isFastMode: isFastMode
            ))
            start = change.date
            isFastMode = change.isFastMode
        }
        result.append(ActivityInterval(
            start: start,
            end: interval.end,
            isFastMode: isFastMode
        ))
        return result
    }

}
