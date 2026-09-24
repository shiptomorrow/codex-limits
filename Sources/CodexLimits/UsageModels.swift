import Foundation

enum UsagePercentageDisplay {
    static let showsUsedKey = "showUsedPercentage"

    static var showsUsed: Bool {
        UserDefaults.standard.bool(forKey: showsUsedKey)
    }

    static func value(remainingPercent: Double, showsUsed: Bool) -> Double {
        let remaining = min(max(remainingPercent, 0), 100)
        return showsUsed ? 100 - remaining : remaining
    }
}

enum UsageChartPreferences {
    static let showsTargetHoverLabelKey = "showTargetHoverLabel"
}

enum EstimatedRuntimeChartPreferences {
    static let reversesYAxisKey = "reverseEstimatedRuntimeChart"
    static let proratesShortWindowsKey = "prorateShortUsageWindows"
    static let proratingThresholdMinutesKey = "proratingThresholdMinutes"
    static let proratingDistanceMinutesKey = "proratingDistanceMinutes"
    static let percentagePointLookbackKey = "estimatedRuntimePercentagePointLookback"
    static let defaultProratingThresholdMinutes = 15
    static let defaultProratingDistanceMinutes = 30
    static let defaultPercentagePointLookback = 1

    static func clampedProratingThreshold(_ minutes: Int) -> Int {
        min(max(minutes, 1), 60)
    }

    static func clampedProratingDistance(_ minutes: Int) -> Int {
        min(max(minutes, 5), 180)
    }

    static func clampedPercentagePointLookback(_ points: Int) -> Int {
        min(max(points, 1), 10)
    }
}

enum OtherLimitPreferences {
    static let hideCodex53SparkKey = "hideCodex53SparkLimit"

    static func visibleLimits(
        from limits: [LimitReading],
        hideCodex53Spark: Bool
    ) -> [LimitReading] {
        guard hideCodex53Spark else { return limits }
        return limits.filter { !isCodex53Spark($0) }
    }

    private static func isCodex53Spark(_ limit: LimitReading) -> Bool {
        let identity = "\(limit.limitId) \(limit.name)"
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return identity.contains("53") && identity.contains("spark")
    }
}

enum UsageLimitWindow: String, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case weekly

    static let preferenceKey = "selectedUsageLimitWindow"

    static var current: UsageLimitWindow {
        UserDefaults.standard.string(forKey: preferenceKey)
            .flatMap(UsageLimitWindow.init(rawValue:)) ?? .fiveHour
    }

    var id: String { rawValue }

    var durationMinutes: Int {
        switch self {
        case .fiveHour: 300
        case .weekly: 10_080
        }
    }

    var label: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "Weekly"
        }
    }

    /// Older history mixed both windows. A 5-hour sample always resets within
    /// five hours of being observed.
    static func isFiveHourSample(_ sample: UsageSample) -> Bool {
        sample.resetsAt.timeIntervalSince(sample.observedAt)
            <= 5 * 3_600 + UsageReadingValidation.resetTolerance
    }

    static func available(in snapshot: UsageSnapshot) -> [UsageLimitWindow] {
        allCases.filter { $0.reading(in: snapshot) != nil }
    }

    func reading(in snapshot: UsageSnapshot) -> LimitReading? {
        ([snapshot.mainLimit] + snapshot.otherLimits).first {
            $0.limitId == snapshot.mainLimit.limitId
                && $0.window.durationMinutes == durationMinutes
        }
    }

    /// Makes this window the main limit, falling back to the other window
    /// when the service does not report this one.
    func applied(to snapshot: UsageSnapshot) -> UsageSnapshot {
        guard let chosen = reading(in: snapshot)
                ?? Self.allCases.lazy.compactMap({ $0.reading(in: snapshot) }).first,
              chosen != snapshot.mainLimit else { return snapshot }

        let mainID = snapshot.mainLimit.limitId
        let others = ([snapshot.mainLimit] + snapshot.otherLimits)
            .filter { $0 != chosen }
            .map { limit in
                guard limit.limitId == mainID else { return limit }
                return LimitReading(
                    limitId: mainID,
                    name: Self.windowName(limit.window.durationMinutes),
                    window: limit.window
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return UsageSnapshot(
            mainLimit: LimitReading(
                limitId: mainID,
                name: snapshot.mainLimit.name,
                window: chosen.window
            ),
            otherLimits: others,
            tokenHistory: snapshot.tokenHistory,
            emergencyResetCount: snapshot.emergencyResetCount,
            nextEmergencyResetExpiration: snapshot.nextEmergencyResetExpiration,
            fetchedAt: snapshot.fetchedAt,
            planType: snapshot.planType
        )
    }

    private static func windowName(_ minutes: Int) -> String {
        if minutes == 10_080 { return "Weekly window" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour window" }
        return "Additional window"
    }
}

struct UsageWindow: Codable, Equatable, Sendable {
    let remainingPercent: Double
    let resetsAt: Date
    let durationMinutes: Int

    var startsAt: Date {
        resetsAt.addingTimeInterval(-Double(durationMinutes) * 60)
    }

}

struct UsageSample: Codable, Equatable, Hashable, Sendable {
    let observedAt: Date
    let remainingPercent: Double
    let resetsAt: Date

    private enum CodingKeys: String, CodingKey {
        case observedAt
        case date
        case remainingPercent
        case resetsAt
    }

    init(observedAt: Date, remainingPercent: Double, resetsAt: Date) {
        self.observedAt = observedAt
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
            ?? container.decode(Date.self, forKey: .date)
        remainingPercent = try container.decode(Double.self, forKey: .remainingPercent)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
    }
}

struct HistoricalUsageWindow: Equatable, Sendable {
    let window: UsageWindow
    let samples: [UsageSample]
    let fetchedAt: Date
}

enum UsageReadingValidation {
    static let resetTolerance: TimeInterval = 5 * 60
    static let confirmationMaximumDecrease = 2.0

    static func removingImplausibleIncreases(from samples: [UsageSample]) -> [UsageSample] {
        var accepted: [UsageSample] = []
        var pendingIncrease: [UsageSample] = []

        for sample in samples.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard let baseline = accepted.last else {
                accepted.append(sample)
                continue
            }

            guard isSameWindow(
                resetsAt: sample.resetsAt,
                previousReset: baseline.resetsAt
            ) else {
                pendingIncrease.removeAll()
                accepted.append(sample)
                continue
            }

            guard let pending = pendingIncrease.last else {
                if sample.remainingPercent <= baseline.remainingPercent {
                    accepted.append(sample)
                } else {
                    pendingIncrease = [sample]
                }
                continue
            }

            if sample.remainingPercent <= baseline.remainingPercent {
                pendingIncrease.removeAll()
                accepted.append(sample)
                continue
            }

            let decrease = pending.remainingPercent - sample.remainingPercent
            if decrease > 0, decrease <= confirmationMaximumDecrease {
                accepted.append(contentsOf: pendingIncrease)
                accepted.append(sample)
                pendingIncrease.removeAll()
            } else if decrease > confirmationMaximumDecrease {
                pendingIncrease = [sample]
            } else {
                pendingIncrease.append(sample)
            }
        }
        return accepted
    }

    static func isSameWindow(
        resetsAt: Date,
        previousReset: Date,
        tolerance: TimeInterval = resetTolerance
    ) -> Bool {
        abs(resetsAt.timeIntervalSince(previousReset)) <= tolerance
    }

    static func samples(
        _ samples: [UsageSample],
        matchingReset reset: Date
    ) -> [UsageSample] {
        samples
            .filter {
                isSameWindow(
                    resetsAt: $0.resetsAt,
                    previousReset: reset
                )
            }
            .sorted { $0.observedAt < $1.observedAt }
    }

    static func historicalWindows(
        in samples: [UsageSample],
        before currentWindow: UsageWindow
    ) -> [HistoricalUsageWindow] {
        let groups = samples
            .sorted { $0.observedAt < $1.observedAt }
            .reduce(into: [[UsageSample]]()) { groups, sample in
                guard let reset = groups.last?.last?.resetsAt,
                      isSameWindow(resetsAt: sample.resetsAt, previousReset: reset) else {
                    groups.append([sample])
                    return
                }
                groups[groups.count - 1].append(sample)
            }
        let currentGroupIndex = groups.lastIndex { group in
            guard let reset = group.last?.resetsAt else { return false }
            return isSameWindow(
                resetsAt: reset,
                previousReset: currentWindow.resetsAt
            )
        }
        let historicalIndices = groups.indices.filter { index in
            currentGroupIndex.map { index < $0 } ?? true
        }

        let windows: [HistoricalUsageWindow] = historicalIndices.compactMap {
            index -> HistoricalUsageWindow? in
            guard let lastSample = groups[index].last else { return nil }

            let scheduledReset = lastSample.resetsAt
            let plannedStart = scheduledReset.addingTimeInterval(
                -Double(currentWindow.durationMinutes) * 60
            )
            let nextWindowStartedAt = groups.indices.contains(index + 1)
                ? groups[index + 1].first?.observedAt
                : nil
            let endedAt = min(nextWindowStartedAt ?? scheduledReset, scheduledReset)
            guard endedAt > plannedStart else { return nil }
            let windowSamples = groups[index].filter { $0.observedAt <= endedAt }
            guard let endingSample = windowSamples.last else { return nil }

            return HistoricalUsageWindow(
                window: UsageWindow(
                    remainingPercent: endingSample.remainingPercent,
                    resetsAt: scheduledReset,
                    durationMinutes: currentWindow.durationMinutes
                ),
                samples: windowSamples,
                fetchedAt: endedAt
            )
        }
        return Array(windows.reversed())
    }
}

struct TokenDay: Codable, Equatable, Sendable {
    let date: Date
    let tokens: Int64
}

struct LimitReading: Codable, Equatable, Identifiable, Sendable {
    let limitId: String
    let name: String
    let window: UsageWindow

    var id: String { "\(limitId)-\(window.durationMinutes)" }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    let mainLimit: LimitReading
    let otherLimits: [LimitReading]
    let tokenHistory: [TokenDay]
    let emergencyResetCount: Int
    let nextEmergencyResetExpiration: Date?
    let fetchedAt: Date
    let planType: String?

    var subscriptionName: String? {
        switch planType {
        case "free": "Codex Free"
        case "go": "Codex Go"
        case "plus": "Codex Plus"
        case "prolite": "Codex Pro 5×"
        case "pro": "Codex Pro 20×"
        case "team": "Codex Team"
        case "self_serve_business_usage_based", "business": "Codex Business"
        case "enterprise_cbp_usage_based", "enterprise": "Codex Enterprise"
        case "edu": "Codex Edu"
        case "claude_free": "Claude Free"
        case "claude_pro": "Claude Pro"
        case "claude_max": "Claude Max"
        case "claude_max_5x": "Claude Max 5×"
        case "claude_max_20x": "Claude Max 20×"
        case "claude_team": "Claude Team"
        case "claude_enterprise": "Claude Enterprise"
        default: nil
        }
    }
}

extension UsageSnapshot {
    /// The same reading, stamped as observed at `date`.
    func refetched(at date: Date) -> UsageSnapshot {
        UsageSnapshot(
            mainLimit: mainLimit,
            otherLimits: otherLimits,
            tokenHistory: tokenHistory,
            emergencyResetCount: emergencyResetCount,
            nextEmergencyResetExpiration: nextEmergencyResetExpiration,
            fetchedAt: date,
            planType: planType
        )
    }
}

enum PaceStatus: String, Codable, Equatable, Sendable {
    case slowDown
    case onTrack
    case roomToUseMore
}

struct Forecast: Equatable, Sendable {
    let status: PaceStatus
    let expectedRemainingAtReset: Double
    let safetyRemainingAtReset: Double
    let historicalRemainingAtReset: Double
    let recommendedPercentPerDay: Double
    let currentPercentPerDay: Double
    let historicalPercentPerDay: Double
    let safetyPercentPerDay: Double
}
