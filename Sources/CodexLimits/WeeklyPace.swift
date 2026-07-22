import Foundation

struct ActivityInterval: Equatable, Sendable {
    let start: Date
    let end: Date

    var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

struct WeeklyPaceEstimate: Equatable, Sendable {
    let hoursPerWeek: Double
    let activeDuration: TimeInterval
    let percentagePointsUsed: Double
}

struct WeeklyPacePoint: Equatable, Identifiable, Sendable {
    let date: Date
    let hoursPerWeek: Double
    let windowResetsAt: Date

    var id: Date { date }
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
            .filter { $0.end >= samples[0].observedAt && $0.start <= now }
        guard !blocks.isEmpty else { return nil }

        if let last = blocks.last, now.timeIntervalSince(last.end) <= idleGap {
            blocks[blocks.count - 1] = ActivityInterval(start: last.start, end: now)
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
            percentagePointsUsed: measured.used
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

        return windows.flatMap { windowSamples in
            estimateSingleWindowSeries(
                samples: windowSamples,
                activity: activity,
                now: now,
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
        sampleTolerance: TimeInterval,
        factorInPauses: Bool,
        lookback: TimeInterval,
        minimumPointSpacing: TimeInterval
    ) -> [WeeklyPacePoint] {
        let samples = samples.sorted { $0.observedAt < $1.observedAt }
        guard samples.count > 1 else { return [] }

        var candidateIndices: [Int] = []
        var lastCandidateDate: Date?
        for index in samples.indices.dropFirst() {
            let sample = samples[index]
            let usageChanged = sample.remainingPercent != samples[index - 1].remainingPercent
            let spacingReached = lastCandidateDate.map {
                sample.observedAt.timeIntervalSince($0) >= minimumPointSpacing
            } ?? true
            if usageChanged || spacingReached || index == samples.indices.last {
                candidateIndices.append(index)
                lastCandidateDate = sample.observedAt
            }
        }

        return candidateIndices.compactMap { index in
            let date = samples[index].observedAt
            guard let estimate = estimate(
                samples: Array(samples[...index]),
                activity: activity,
                now: date,
                sampleTolerance: sampleTolerance,
                factorInPauses: factorInPauses,
                lookback: lookback
            ) else { return nil }
            return WeeklyPacePoint(
                date: date,
                hoursPerWeek: estimate.hoursPerWeek,
                windowResetsAt: samples[index].resetsAt
            )
        }
    }

    static func merged(
        _ intervals: [ActivityInterval],
        joiningGapsUpTo allowedGap: TimeInterval
    ) -> [ActivityInterval] {
        intervals
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
            .reduce(into: []) { result, interval in
                guard let last = result.last else {
                    result.append(interval)
                    return
                }
                if interval.start.timeIntervalSince(last.end) <= allowedGap {
                    result[result.count - 1] = ActivityInterval(
                        start: last.start,
                        end: max(last.end, interval.end)
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
                end: block.end
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
        return ActivityInterval(start: start, end: end)
    }

    private static func measurement(
        samples: [UsageSample],
        intervals: [ActivityInterval],
        tolerance: TimeInterval
    ) -> (used: Double, duration: TimeInterval) {
        let validIntervals = intervals.filter { interval in
            let hasStartSample = samples.last(where: {
                $0.observedAt <= interval.start
                    && interval.start.timeIntervalSince($0.observedAt) <= tolerance
            }) ?? samples.first(where: {
                $0.observedAt > interval.start
                    && $0.observedAt.timeIntervalSince(interval.start) <= tolerance
            })
            let hasEndSample = samples.first(where: {
                $0.observedAt >= interval.end
                    && $0.observedAt.timeIntervalSince(interval.end) <= tolerance
            }) ?? samples.last(where: {
                $0.observedAt < interval.end
                    && interval.end.timeIntervalSince($0.observedAt) <= tolerance
            })
            return hasStartSample != nil && hasEndSample != nil
        }

        let duration = validIntervals.reduce(0) { $0 + $1.duration }
        let used = samples.indices.dropFirst().reduce(0.0) { total, index in
            let previous = samples[index - 1]
            let current = samples[index]
            let decrease = max(previous.remainingPercent - current.remainingPercent, 0)
            guard decrease > 0 else { return total }

            let belongsToActivity = validIntervals.contains { interval in
                current.observedAt > interval.start
                    && current.observedAt <= interval.end.addingTimeInterval(tolerance)
                    && previous.observedAt <= interval.end
            }
            return belongsToActivity ? total + decrease : total
        }

        return (used, duration)
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
        var completed: [String: ActivityInterval] = [:]
        var tokenTimesByFile: [URL: [Date]] = [:]

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            contents.enumerateLines { line, _ in
                guard line.contains("\"event_msg\"") else { return }
                let isRelevant = line.contains("\"task_started\"")
                    || line.contains("\"task_complete\"")
                    || line.contains("\"token_count\"")
                guard isRelevant,
                      let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { return }

                switch type {
                case "task_started":
                    guard let turnID = payload["turn_id"] as? String,
                          let startedAt = seconds(payload["started_at"]) else { return }
                    starts[turnID] = (Date(timeIntervalSince1970: startedAt), file)
                case "task_complete":
                    guard let turnID = payload["turn_id"] as? String,
                          let startedAt = seconds(payload["started_at"]),
                          let completedAt = seconds(payload["completed_at"]) else { return }
                    completedIDs.insert(turnID)
                    completed[turnID] = ActivityInterval(
                        start: Date(timeIntervalSince1970: startedAt),
                        end: Date(timeIntervalSince1970: completedAt)
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

        var intervals = Array(completed.values)
        for (turnID, start) in starts where !completedIDs.contains(turnID) {
            let end = tokenTimesByFile[start.file, default: []]
                .filter { $0 >= start.date && $0 <= now }
                .max() ?? start.date
            if end > start.date {
                intervals.append(ActivityInterval(start: start.date, end: end))
            }
        }
        return intervals.filter { $0.end >= since && $0.start <= now }
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
