import CryptoKit
import Foundation

/// Account identity, hashed the same way as the server usage logger so raw IDs never leave either machine.
enum UsageAccountIdentity {
    nonisolated static func hash(provider: UsageProvider, accountID: String) -> String {
        SHA256.hash(data: Data("\(provider.rawValue):\(accountID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func local(for provider: UsageProvider) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountID: String?
        switch provider {
        case .codex:
            let root = environment["CODEX_HOME"].map(expandedURL)
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            let tokens = jsonObject(at: root.appendingPathComponent("auth.json"))?["tokens"]
            accountID = (tokens as? [String: Any])?["account_id"] as? String
        case .claude:
            let config = environment["CLAUDE_CONFIG_DIR"]
                .map { expandedURL($0).appendingPathComponent(".claude.json") }
                ?? home.appendingPathComponent(".claude.json")
            let account = jsonObject(at: config)?["oauthAccount"]
            accountID = (account as? [String: Any])?["accountUuid"] as? String
        }
        guard let accountID, !accountID.isEmpty else { return nil }
        return hash(provider: provider, accountID: accountID)
    }

    nonisolated private static func expandedURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
    }

    nonisolated private static func jsonObject(at url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

enum ServerUsageLogError: LocalizedError, Equatable {
    case helperMissing
    case unsupportedResponse
    case logger(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing: "Server usage logger is missing from the app"
        case .unsupportedResponse: "Unsupported server usage log response"
        case let .logger(message): message
        }
    }
}

/// What a server's usage logger has recorded since the last import.
struct ServerUsageLogExport: Equatable, Sendable {
    let installed: Bool
    let lastRunAt: Date?
    let lastSuccessAt: Date?
    /// The logger's most recent failure, already phrased for display.
    let lastError: String?
    let fiveHourSamples: [UsageSample]
    let weeklySamples: [UsageSample]
    /// Timestamp of the newest entry, used as the cursor for the next import.
    let newestEntryTime: TimeInterval?
    let otherAccountEntryCount: Int
    /// While this is in the future, the logger only checks every `macLoggingCheckInterval`.
    let macLoggingUntil: Date?
}

/// Installs and reads the cron-driven usage logger in `Resources/remote-usage.py`.
enum ServerUsageLog {
    static let importInterval: TimeInterval = 10 * 60
    /// Cron runs the logger every one or two minutes and Claude backoff usually skips at most five minutes,
    /// so an older run means the logger stopped.
    static let staleRunInterval: TimeInterval = 10 * 60
    /// Mirrors `MAC_LOGGING_CHECK_INTERVAL`: how often servers check while this Mac reads usage itself.
    static let macLoggingCheckInterval: TimeInterval = 10 * 60
    /// Outlasts one import interval, so the lease lapses soon after this Mac sleeps or quits.
    static let macLoggingLease: TimeInterval = 15 * 60
    /// This Mac counts as reading usage only if its last successful read is this recent.
    static let macReadFreshness: TimeInterval = 5 * 60

    /// Mirrors `CRON_SCHEDULES` in the logger.
    nonisolated static func checkInterval(for provider: UsageProvider) -> TimeInterval {
        provider == .claude ? 2 * 60 : 60
    }

    nonisolated static func describe(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return minutes == 1 ? "every minute" : "every \(minutes) minutes"
    }
    private static let operationTimeout: TimeInterval = 90
    private static let scriptName = "remote-usage"

    static var scriptURL: URL? {
        RemoteSSHCommand.scriptURL(named: scriptName)
    }

    /// Changes whenever the bundled logger changes, so hosts can be updated.
    static var scriptHash: String? {
        guard let scriptURL, let data = try? Data(contentsOf: scriptURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// History writer for samples logged on `profile`, kept apart from this Mac's own samples.
    static func historyWriter(for profile: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let safe = String(profile.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "server-\(safe)"
    }

    /// Copies the logger to `~/.codex-limits` on the host, schedules it in the user's crontab, and runs it once.
    static func install(profile: String, provider: UsageProvider) async throws -> ServerUsageLogExport {
        guard let scriptURL else { throw ServerUsageLogError.helperMissing }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let script = "~/.codex-limits/remote-usage.py"
        let output = try await RemoteSSHCommand.run(
            profile: profile,
            input: scriptURL,
            remoteCommand: [
                "umask 077",
                "mkdir -p ~/.codex-limits",
                "cat > \(script).new",
                "mv \(script).new \(script)",
                "python3 \(script) install \(provider.rawValue) \(version)"
            ].joined(separator: " && "),
            timeout: operationTimeout,
            purpose: "usage logger install"
        )
        return try decodeExport(output, provider: provider, localAccount: nil)
    }

    /// Removes the cron entry. The log stays on the host.
    static func uninstall(profile: String, provider: UsageProvider) async throws {
        guard let scriptURL else { throw ServerUsageLogError.helperMissing }
        let output = try await RemoteSSHCommand.run(
            profile: profile,
            script: scriptURL,
            arguments: ["uninstall", provider.rawValue],
            timeout: operationTimeout,
            purpose: "usage logger removal"
        )
        _ = try decodeExport(output, provider: provider, localAccount: nil)
    }

    /// Also passes `macLoggingUntil`, or 0 when this Mac isn't reading usage, so the logger can slow down.
    static func export(
        profile: String,
        provider: UsageProvider,
        since: TimeInterval,
        macLoggingUntil: Date?
    ) async throws -> ServerUsageLogExport {
        guard let scriptURL else { throw ServerUsageLogError.helperMissing }
        let output = try await RemoteSSHCommand.run(
            profile: profile,
            script: scriptURL,
            arguments: [
                "export",
                provider.rawValue,
                String(since),
                String(macLoggingUntil?.timeIntervalSince1970 ?? 0)
            ],
            timeout: operationTimeout,
            purpose: "usage log export"
        )
        let localAccount = await Task.detached(priority: .utility) {
            UsageAccountIdentity.local(for: provider)
        }.value
        do {
            return try decodeExport(output, provider: provider, localAccount: localAccount)
        } catch ServerUsageLogError.unsupportedResponse {
            CodexDiagnostics.record(
                "Server usage log could not be decoded for profile \(profile)",
                details: String(decoding: output.prefix(4_000), as: UTF8.self)
            )
            throw ServerUsageLogError.unsupportedResponse
        }
    }

    nonisolated static func decodeExport(
        _ data: Data,
        provider: UsageProvider,
        localAccount: String?
    ) throws -> ServerUsageLogExport {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1 else {
            throw ServerUsageLogError.unsupportedResponse
        }
        if let code = object["error"] as? String {
            throw ServerUsageLogError.logger(message(forLoggerError: code, provider: provider))
        }

        let state = object["state"] as? [String: Any] ?? [:]
        let date = { (key: String) in
            (state[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }
        var fiveHour: [UsageSample] = []
        var weekly: [UsageSample] = []
        var newest: TimeInterval?
        var otherAccountEntries = 0
        for entry in object["entries"] as? [[String: Any]] ?? [] {
            guard let time = (entry["t"] as? NSNumber)?.doubleValue else { continue }
            newest = max(newest ?? time, time)
            // A host signed in elsewhere would mix another account's usage into this history.
            if let account = entry["account"] as? String, let localAccount, account != localAccount {
                otherAccountEntries += 1
                continue
            }
            for window in entry["windows"] as? [[String: Any]] ?? [] {
                guard let minutes = window["minutes"] as? Int,
                      let remaining = (window["remaining"] as? NSNumber)?.doubleValue,
                      let resetsAt = (window["resetsAt"] as? NSNumber)?.doubleValue else { continue }
                let sample = UsageSample(
                    observedAt: Date(timeIntervalSince1970: time),
                    remainingPercent: remaining,
                    resetsAt: Date(timeIntervalSince1970: resetsAt)
                )
                if minutes == UsageLimitWindow.fiveHour.durationMinutes {
                    fiveHour.append(sample)
                } else if minutes == UsageLimitWindow.weekly.durationMinutes {
                    weekly.append(sample)
                }
            }
        }

        return ServerUsageLogExport(
            installed: object["installed"] as? Bool ?? false,
            lastRunAt: date("lastRunAt"),
            lastSuccessAt: date("lastSuccessAt"),
            lastError: (state["lastError"] as? String).map {
                message(forLoggerError: $0, provider: provider)
            },
            fiveHourSamples: fiveHour,
            weeklySamples: weekly,
            newestEntryTime: newest,
            otherAccountEntryCount: otherAccountEntries,
            macLoggingUntil: (object["macLoggingUntil"] as? NSNumber).flatMap {
                $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil
            }
        )
    }

    nonisolated static func message(forLoggerError code: String, provider: UsageProvider) -> String {
        if code.hasPrefix("rpc:") {
            let message = String(code.dropFirst(4))
            return CodexClient.error(forRPCMessage: message.isEmpty ? nil : message)
                .errorDescription ?? message
        }
        switch code {
        case "cronMissing":
            return "cron isn’t available on this host, so usage can’t be logged there."
        case "cronFailed":
            return "Couldn’t update the crontab on this host."
        case "cliNotFound":
            return "Codex CLI wasn’t found on this host."
        case "credentialsNotFound":
            return "Claude Code isn’t signed in on this host."
        default:
            break
        }
        let error: LocalizedError? = switch (code, provider) {
        case ("authenticationFailed", .codex): CodexClientError.authenticationFailed
        case ("authenticationFailed", .claude): ClaudeClientError.authenticationFailed
        case ("timedOut", .codex): CodexClientError.timedOut
        case ("timedOut", .claude): ClaudeClientError.timedOut
        case ("connectionFailed", .codex): CodexClientError.connectionFailed
        case ("connectionFailed", .claude): ClaudeClientError.connectionFailed
        case ("mainLimitMissing", .codex): CodexClientError.mainLimitMissing
        case ("mainLimitMissing", .claude): ClaudeClientError.mainLimitMissing
        case ("serviceUnavailable", _): ClaudeClientError.serviceUnavailable
        case ("rateLimited", _): ClaudeClientError.rateLimited
        case ("requestFailed", _): ClaudeClientError.requestFailed
        case (_, .codex): CodexClientError.invalidResponse
        case (_, .claude): ClaudeClientError.invalidResponse
        }
        return error?.errorDescription ?? code
    }
}
