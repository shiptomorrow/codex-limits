import Foundation

enum ClaudeClientError: LocalizedError, Equatable {
    case credentialsNotFound
    case authenticationFailed
    case invalidResponse
    case mainLimitMissing
    case timedOut
    case connectionFailed
    case serviceUnavailable
    case rateLimited
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            "Claude Code sign-in was not found. Install Claude Code, run /login, and try again."
        case .authenticationFailed:
            "Claude Code sign-in expired. Open Claude Code to renew it, then try refreshing."
        case .invalidResponse:
            "Claude returned usage data this app could not read."
        case .mainLimitMissing:
            "Claude has not reported a usage window yet. Use Claude Code, then refresh."
        case .timedOut:
            "Claude took too long to respond. Try refreshing again."
        case .connectionFailed:
            "Couldn’t reach Claude. Check your internet connection and try refreshing."
        case .serviceUnavailable:
            "Claude usage service is temporarily unavailable. Try refreshing again shortly."
        case .rateLimited:
            "Claude is limiting usage checks. The app will try again in a few minutes."
        case .requestFailed:
            "Claude usage service returned an error. Try refreshing again."
        }
    }
}

struct ClaudeCredentials: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    var planType: String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        switch subscriptionType?.lowercased() {
        case "max":
            if tier.contains("20x") { return "claude_max_20x" }
            if tier.contains("5x") { return "claude_max_5x" }
            return "claude_max"
        case "pro": return "claude_pro"
        case "team": return "claude_team"
        case "enterprise": return "claude_enterprise"
        case "free": return "claude_free"
        default: return nil
        }
    }

    static func decode(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}

/// Reads Claude subscription limits with the OAuth token Claude Code stores.
/// The token is never refreshed here: refresh tokens rotate, and refreshing
/// outside Claude Code would sign Claude Code out.
@MainActor
final class ClaudeClient: UsageClient {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated private static let keychainService = "Claude Code-credentials"
    /// The usage endpoint is rate limited, so poll it at most once a minute.
    private static let minimumFetchInterval: TimeInterval = 60
    private static let defaultRateLimitBackoff: TimeInterval = 5 * 60

    private let session: URLSession
    private let now: () -> Date
    private var credentials: ClaudeCredentials?
    private var lastSnapshot: UsageSnapshot?
    private var lastRequestAt: Date?
    private var backoffUntil: Date?

    init(session: URLSession? = nil, now: @escaping () -> Date = { Date() }) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

    func fetch() async throws -> UsageSnapshot {
        let currentDate = now()
        if let backoffUntil, currentDate < backoffUntil {
            guard let lastSnapshot else { throw ClaudeClientError.rateLimited }
            return lastSnapshot.refetched(at: currentDate)
        }
        if let lastSnapshot, let lastRequestAt,
           currentDate.timeIntervalSince(lastRequestAt) < Self.minimumFetchInterval {
            return lastSnapshot.refetched(at: currentDate)
        }

        for attempt in 0...1 {
            let credentials = try await currentCredentials(forceReload: attempt > 0)
            if let expiresAt = credentials.expiresAt, expiresAt <= currentDate {
                // Claude Code may have renewed the token since it was cached.
                if attempt == 0 { continue }
                throw ClaudeClientError.authenticationFailed
            }

            var request = URLRequest(url: Self.usageURL)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
            request.setValue("codex-limits/\(version)", forHTTPHeaderField: "User-Agent")

            let data: Data
            let response: URLResponse
            do {
                lastRequestAt = currentDate
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                CodexDiagnostics.record("Claude usage request failed", details: "\(error)")
                throw error.code == .timedOut
                    ? ClaudeClientError.timedOut
                    : ClaudeClientError.connectionFailed
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                backoffUntil = nil
                let snapshot = try Self.decode(
                    data,
                    planType: credentials.planType,
                    fetchedAt: now()
                )
                lastSnapshot = snapshot
                return snapshot
            case 401, 403:
                if attempt == 0 { continue }
                CodexDiagnostics.record(
                    "Claude usage request was not authorized",
                    details: "Status: \(status)"
                )
                throw ClaudeClientError.authenticationFailed
            case 429:
                let retryAfter = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Retry-After")
                    .flatMap(TimeInterval.init) ?? Self.defaultRateLimitBackoff
                backoffUntil = currentDate.addingTimeInterval(max(retryAfter, Self.minimumFetchInterval))
                CodexDiagnostics.record(
                    "Claude usage request was rate limited",
                    details: "Retry after: \(Int(retryAfter)) seconds"
                )
                guard let lastSnapshot else { throw ClaudeClientError.rateLimited }
                return lastSnapshot.refetched(at: currentDate)
            case 500...599:
                throw ClaudeClientError.serviceUnavailable
            default:
                CodexDiagnostics.record(
                    "Claude usage request failed",
                    details: "Status: \(status)\n\(String(decoding: data.prefix(2_000), as: UTF8.self))"
                )
                throw ClaudeClientError.requestFailed
            }
        }
        throw ClaudeClientError.authenticationFailed
    }

    func shutdown() {
        session.invalidateAndCancel()
    }

    private func currentCredentials(forceReload: Bool) async throws -> ClaudeCredentials {
        if !forceReload, let credentials {
            return credentials
        }
        guard let loaded = await Task.detached(priority: .utility, operation: {
            Self.loadCredentials()
        }).value else {
            credentials = nil
            throw ClaudeClientError.credentialsNotFound
        }
        credentials = loaded
        return loaded
    }

    nonisolated private static func loadCredentials() -> ClaudeCredentials? {
        if let data = keychainCredentials(), let credentials = ClaudeCredentials.decode(data) {
            return credentials
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return (try? Data(contentsOf: file)).flatMap(ClaudeCredentials.decode)
    }

    nonisolated private static func keychainCredentials() -> Data? {
        // Claude Code writes this item with the security tool, which is therefore
        // trusted to read it back without a keychain prompt.
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    nonisolated static func decode(
        _ data: Data,
        planType: String?,
        fetchedAt: Date
    ) throws -> UsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            CodexDiagnostics.record(
                "Could not decode Claude usage response",
                details: String(decoding: data.prefix(4_000), as: UTF8.self)
            )
            throw ClaudeClientError.invalidResponse
        }

        let mainWindows = [
            window(object["five_hour"], durationMinutes: 300),
            window(object["seven_day"], durationMinutes: 10_080)
        ].compactMap { $0 }
        guard let mainWindow = mainWindows.min(by: {
            $0.remainingPercent < $1.remainingPercent
        }) else {
            throw ClaudeClientError.mainLimitMissing
        }
        let mainID = UsageProvider.claude.mainLimitID

        let extraMainWindows = mainWindows
            .filter { $0 != mainWindow }
            .map {
                LimitReading(
                    limitId: mainID,
                    name: $0.durationMinutes == 10_080 ? "Weekly window" : "5-hour window",
                    window: $0
                )
            }

        var scopedLimits: [LimitReading] = []
        if let limits = object["limits"] as? [[String: Any]] {
            scopedLimits = limits.compactMap(scopedLimit)
        } else {
            for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                guard let window = window(object[key], durationMinutes: 10_080) else { continue }
                scopedLimits.append(LimitReading(
                    limitId: "\(mainID)-\(name.lowercased())",
                    name: "\(name) weekly",
                    window: window
                ))
            }
        }

        // Fable weekly always sorts last; everything else is alphabetical.
        let isFableWeekly = { (limit: LimitReading) in limit.name.lowercased() == "fable weekly" }
        let others = (extraMainWindows + scopedLimits).sorted {
            if isFableWeekly($0) != isFableWeekly($1) { return isFableWeekly($1) }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return UsageSnapshot(
            mainLimit: LimitReading(limitId: mainID, name: "Claude", window: mainWindow),
            otherLimits: others,
            tokenHistory: [],
            emergencyResetCount: 0,
            nextEmergencyResetExpiration: nil,
            fetchedAt: fetchedAt,
            planType: planType
        )
    }

    nonisolated private static func scopedLimit(_ limit: [String: Any]) -> LimitReading? {
        guard let scope = limit["scope"] as? [String: Any],
              let percent = (limit["percent"] as? NSNumber)?.doubleValue,
              let resetsAt = (limit["resets_at"] as? String).flatMap(date) else { return nil }
        let scopeName = [scope["model"], scope["surface"]]
            .compactMap { value -> String? in
                if let value = value as? String { return value }
                let named = value as? [String: Any]
                return named?["display_name"] as? String ?? named?["id"] as? String
            }
            .first
        guard let scopeName, !scopeName.isEmpty else { return nil }
        let isWeekly = (limit["group"] as? String) != "session"
        let slug = scopeName.lowercased().filter { $0.isLetter || $0.isNumber }
        return LimitReading(
            limitId: "\(UsageProvider.claude.mainLimitID)-\(slug)",
            name: "\(scopeName) \(isWeekly ? "weekly" : "session")",
            window: UsageWindow(
                remainingPercent: min(max(100 - percent, 0), 100),
                resetsAt: resetsAt,
                durationMinutes: isWeekly ? 10_080 : 300
            )
        )
    }

    nonisolated private static func window(_ value: Any?, durationMinutes: Int) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let utilization = (value["utilization"] as? NSNumber)?.doubleValue,
              let resetsAt = (value["resets_at"] as? String).flatMap(date) else { return nil }
        return UsageWindow(
            remainingPercent: min(max(100 - utilization, 0), 100),
            resetsAt: resetsAt,
            durationMinutes: durationMinutes
        )
    }

    /// Parses reset timestamps, dropping the microseconds the API includes.
    /// Resets fall on whole minutes, and the jitter would split history windows.
    nonisolated static func date(_ value: String) -> Date? {
        var text = value
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { "+-Z".contains($0) }) {
            text.removeSubrange(dot ..< end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private extension UsageSnapshot {
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
