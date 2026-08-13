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
}

struct WeeklyPacePoint: Equatable, Identifiable, Sendable {
    let date: Date
    let hoursPerWeek: Double
    let windowResetsAt: Date
    var isFastMode = false

    var id: Date { date }
}

enum DailyRuntimeCalculator {
    static let dayStartHour = 7
    static let completedDayCount = 2
    static let historicalDayCount = 14
    static let minimumIncludedDayHours = 5.0 / 60

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

        return WeeklyPaceEstimate(
            hoursPerWeek: 100 / usedPerActiveHour,
            activeDuration: measured.duration,
            percentagePointsUsed: measured.used,
            isFastMode: measured.isFastMode
        )
    }

    static func estimateSeries(
        samples rawSamples: [UsageSample],
        activity: [ActivityInterval],
        now: Date,
        sampleTolerance: TimeInterval,
        factorInPauses: Bool,
        lookback: TimeInterval = 60 * 60,
        minimumPointSpacing: TimeInterval = 15 * 60
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

        return windows.indices.flatMap { index in
            let windowSamples = windows[index]
            let nextWindowStart = windows.indices.contains(index + 1)
                ? windows[index + 1].first?.observedAt
                : nil
            let lastObservation = windowSamples.last?.observedAt ?? now
            let seriesEnd = min(
                now,
                max(lastObservation, nextWindowStart ?? now)
            )
            return estimateSingleWindowSeries(
                samples: windowSamples,
                activity: activity,
                now: now,
                seriesEnd: seriesEnd,
                freezeUnmeasuredTail: nextWindowStart == nil,
                sampleTolerance: sampleTolerance,
                factorInPauses: factorInPauses,
                lookback: lookback,
                minimumPointSpacing: minimumPointSpacing
            )
        }
        .sorted { $0.date < $1.date }
    }

    private static func estimateSingleWindowSeries(
        samples: [UsageSample],
        activity: [ActivityInterval],
        now: Date,
        seriesEnd: Date,
        freezeUnmeasuredTail: Bool,
        sampleTolerance: TimeInterval,
        factorInPauses: Bool,
        lookback: TimeInterval,
        minimumPointSpacing: TimeInterval
    ) -> [WeeklyPacePoint] {
        let samples = samples.sorted { $0.observedAt < $1.observedAt }
        guard samples.count > 1 else { return [] }

        let lastUsageChangeDate = freezeUnmeasuredTail
            ? samples.indices.dropFirst().last(where: {
                samples[$0].remainingPercent < samples[$0 - 1].remainingPercent
            }).map { samples[$0].observedAt }
            : nil

        let firstDate = samples[0].observedAt
        var candidateDates = Set(samples.dropFirst().map(\.observedAt))
        if minimumPointSpacing > 0, seriesEnd > firstDate {
            var date = firstDate.addingTimeInterval(minimumPointSpacing)
            while date < seriesEnd {
                candidateDates.insert(date)
                date = date.addingTimeInterval(minimumPointSpacing)
            }
        }
        candidateDates.insert(seriesEnd)

        let rawPoints: [WeeklyPacePoint] = candidateDates
            .filter { $0 > firstDate && $0 <= now }
            .sorted()
            .compactMap { date in
            // Keep the historical series intact, but freeze its unmeasured tail.
            // Once the last percentage decrease is reached, later activity has no
            // known allowance cost until another decrease is observed.
            let calculationDate = min(date, lastUsageChangeDate ?? date)
            let availableSamples = samples.filter { $0.observedAt <= calculationDate }
            guard let estimate = estimate(
                samples: availableSamples,
                activity: activity,
                now: calculationDate,
                sampleTolerance: sampleTolerance,
                factorInPauses: factorInPauses,
                lookback: lookback
            ) else { return nil }
            return WeeklyPacePoint(
                date: date,
                hoursPerWeek: estimate.hoursPerWeek,
                windowResetsAt: samples[0].resetsAt,
                isFastMode: estimate.isFastMode
            )
        }
        return stabilizedSeries(rawPoints)
    }

    static func stabilizedSeries(_ points: [WeeklyPacePoint]) -> [WeeklyPacePoint] {
        guard points.count >= 3 else { return points }
        return points.indices.map { index in
            guard index >= 2 else { return points[index] }
            let raw = points[index]
            let localValues = points[(index - 2) ... index]
                .map(\.hoursPerWeek)
                .sorted()
            let median = localValues[1]
            // A large one-sample change is usually caused by whole-percentage usage
            // readings or an activity block crossing the rolling lookback boundary.
            // Delay it until a second point confirms the new level.
            guard raw.hoursPerWeek > median * 1.5 || raw.hoursPerWeek < median / 1.5 else {
                return raw
            }
            return WeeklyPacePoint(
                date: raw.date,
                hoursPerWeek: median,
                windowResetsAt: raw.windowResetsAt,
                isFastMode: raw.isFastMode
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
    ) -> (used: Double, duration: TimeInterval, isFastMode: Bool) {
        let duration = intervals.reduce(0) { $0 + $1.duration }
        var latestUsageWasFast = false
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
            let isFastMode = matchingIntervals.contains(where: \.isFastMode)
            latestUsageWasFast = isFastMode
            // The observed allowance decrease already includes any fast-mode cost.
            return total + decrease
        }

        return (used, duration, latestUsageWasFast)
    }
}

enum CodexActivityReader {
    static func loadIntervals(since: Date, now: Date) async -> [ActivityInterval] {
        await Task.detached(priority: .utility) {
            loadIntervalsSynchronously(since: since, now: now)
        }.value
    }

    private static func loadIntervalsSynchronously(since: Date, now: Date) -> [ActivityInterval] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = sessionFiles(in: root, since: since, now: now)
        var starts: [String: (date: Date, file: URL)] = [:]
        var completedIDs: Set<String> = []
        var completed: [String: (interval: ActivityInterval, file: URL)] = [:]
        var tokenTimesByFile: [URL: [Date]] = [:]
        var modeChangesByFile: [URL: [(date: Date, isFastMode: Bool)]] = [:]

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            contents.enumerateLines { line, _ in
                guard line.contains("\"event_msg\"") else { return }
                let isRelevant = line.contains("\"task_started\"")
                    || line.contains("\"task_complete\"")
                    || line.contains("\"token_count\"")
                    || line.contains("\"thread_settings_applied\"")
                guard isRelevant,
                      let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { return }

                switch type {
                case "thread_settings_applied":
                    guard let settings = payload["thread_settings"] as? [String: Any],
                          let serviceTier = settings["service_tier"] as? String,
                          let timestamp = object["timestamp"] as? String,
                          let date = timestampDate(timestamp) else { return }
                    modeChangesByFile[file, default: []].append((
                        date,
                        serviceTier == "fast" || serviceTier == "priority"
                    ))
                case "task_started":
                    guard let turnID = payload["turn_id"] as? String,
                          let startedAt = seconds(payload["started_at"]) else { return }
                    starts[turnID] = (Date(timeIntervalSince1970: startedAt), file)
                case "task_complete":
                    guard let turnID = payload["turn_id"] as? String,
                          let startedAt = seconds(payload["started_at"]),
                          let completedAt = seconds(payload["completed_at"]) else { return }
                    completedIDs.insert(turnID)
                    completed[turnID] = (
                        ActivityInterval(
                            start: Date(timeIntervalSince1970: startedAt),
                            end: Date(timeIntervalSince1970: completedAt)
                        ),
                        file
                    )
                case "token_count":
                    guard let timestamp = object["timestamp"] as? String,
                          let date = timestampDate(timestamp) else { return }
                    tokenTimesByFile[file, default: []].append(date)
                default:
                    break
                }
            }
        }

        let allModeChanges = modeChangesByFile.values.flatMap { $0 }
        var intervals = completed.values.flatMap {
            split(
                $0.interval,
                at: modeChangesByFile[$0.file, default: []],
                inheriting: allModeChanges
            )
        }
        for (turnID, start) in starts where !completedIDs.contains(turnID) {
            let end = tokenTimesByFile[start.file, default: []]
                .filter { $0 >= start.date && $0 <= now }
                .max() ?? start.date
            if end > start.date {
                intervals += split(
                    ActivityInterval(start: start.date, end: end),
                    at: modeChangesByFile[start.file, default: []],
                    inheriting: allModeChanges
                )
            }
        }
        return intervals.filter { $0.end >= since && $0.start <= now }
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

    private static func sessionFiles(in root: URL, since: Date, now: Date) -> [URL] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var day = calendar.startOfDay(for: since.addingTimeInterval(-86_400))
        let finalDay = calendar.startOfDay(for: now.addingTimeInterval(86_400))
        var files: [URL] = []

        while day <= finalDay {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let directory = root
                .appendingPathComponent(String(format: "%04d", components.year!))
                .appendingPathComponent(String(format: "%02d", components.month!))
                .appendingPathComponent(String(format: "%02d", components.day!))
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                files += contents.filter {
                    $0.pathExtension == "jsonl"
                        && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 50_000_000
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return files
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private static func timestampDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
