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
        default: nil
        }
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
