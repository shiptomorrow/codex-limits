import CryptoKit
import Foundation

/// A Claude Code sign-in, identified by its config folder. The default account is the one
/// Claude Code uses without `CLAUDE_CONFIG_DIR`. Every other account is a folder Claude Code
/// was started with through `CLAUDE_CONFIG_DIR`, which gets its own config file, sessions
/// and keychain item.
struct ClaudeAccount: Hashable, Identifiable, Sendable {
    static let preferenceKey = "claudeAccountDirectory"
    static let `default` = ClaudeAccount(configDirectory: nil)

    /// The folder Claude Code was pointed at, or nil for the default account.
    let configDirectory: String?

    var id: String { configDirectory ?? "" }
    var isDefault: Bool { configDirectory == nil }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude Code suffixes the keychain item of a custom config folder with the first
    /// eight hex digits of the folder path's SHA-256.
    var pathHash: String? {
        configDirectory.map { path in
            SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
                .description
        }
    }

    var keychainService: String {
        pathHash.map { "Claude Code-credentials-\($0)" } ?? "Claude Code-credentials"
    }

    /// Holds the signed-in account and Claude Code's latest usage response.
    var configFile: URL {
        configDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? Self.home.appendingPathComponent(".claude.json")
    }

    /// Fallback for when the keychain has no credentials.
    var credentialsFile: URL {
        configDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent(".credentials.json") }
            ?? Self.home.appendingPathComponent(".claude/.credentials.json")
    }

    var projectsDirectory: URL {
        (configDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.home.appendingPathComponent(".claude", isDirectory: true))
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// The default account keeps the unsuffixed storage so its existing history survives.
    func storageKey(_ base: String) -> String {
        pathHash.map { "\(base)-\($0)" } ?? base
    }

    /// The environment for running Claude Code as this account, whichever account the app was launched with.
    func environment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["CLAUDE_CONFIG_DIR"] = configDirectory
        return environment
    }

    /// The selected account, or the default one when the selected folder is gone.
    static var current: ClaudeAccount {
        guard let path = UserDefaults.standard.string(forKey: preferenceKey), !path.isEmpty else {
            return .default
        }
        let account = ClaudeAccount(configDirectory: path)
        return FileManager.default.fileExists(atPath: account.configFile.path) ? account : .default
    }

    static func select(_ account: ClaudeAccount) {
        if let configDirectory = account.configDirectory {
            UserDefaults.standard.set(configDirectory, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
    }
}

struct ClaudeAccountOption: Hashable, Identifiable, Sendable {
    let account: ClaudeAccount
    let label: String
    let email: String?

    var id: String { account.id }

    var help: String {
        let folder = account.configDirectory.map { NSString(string: $0).abbreviatingWithTildeInPath }
            ?? "~/.claude"
        return [email, folder].compactMap { $0 }.joined(separator: " · ")
    }

    /// The default account first, then every `~/.claude*` folder signed in to Claude Code.
    static func discover() -> [ClaudeAccountOption] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let folders = ((try? fileManager.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { url in
                url.lastPathComponent.hasPrefix(".claude")
                    && url.lastPathComponent != ".claude"
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var accounts: [(account: ClaudeAccount, details: SignIn?, folder: String)] = [
            (.default, signIn(of: .default), ".claude")
        ]
        for folder in folders {
            let account = ClaudeAccount(configDirectory: folder.path)
            guard let details = signIn(of: account) else { continue }
            accounts.append((account, details, folder.lastPathComponent))
        }

        // Accounts are named after their plan; the email's local part tells apart two on the same plan.
        let plans = accounts.map { $0.details?.planName }
        return accounts.enumerated().map { index, entry in
            let email = entry.details?.email
            let name = email?.split(separator: "@").first.map(String.init)
            let label: String
            switch (plans[index], name) {
            case let (plan?, name?) where plans.filter({ $0 == plan }).count > 1:
                label = "\(plan) (\(name))"
            case let (plan?, _):
                label = plan
            case let (nil, name?):
                label = name
            case (nil, nil):
                label = entry.folder
            }
            return ClaudeAccountOption(account: entry.account, label: label, email: email)
        }
    }

    private struct SignIn {
        let email: String?
        let planName: String?
    }

    /// nil when the folder isn't signed in to Claude Code.
    private static func signIn(of account: ClaudeAccount) -> SignIn? {
        guard let data = try? Data(contentsOf: account.configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["oauthAccount"] as? [String: Any],
              oauth["accountUuid"] as? String != nil else { return nil }
        return SignIn(
            email: (oauth["emailAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            planName: planName(
                rateLimitTier: oauth["organizationRateLimitTier"] as? String
                    ?? oauth["userRateLimitTier"] as? String,
                organizationType: oauth["organizationType"] as? String
            )
        )
    }

    /// Claude Code records the plan as a rate limit tier such as `default_claude_max_20x`,
    /// and the organization type such as `claude_max`.
    static func planName(rateLimitTier: String?, organizationType: String?) -> String? {
        let tier = rateLimitTier.map { $0.hasPrefix("default_") ? String($0.dropFirst(8)) : $0 }
        return UsageSnapshot.subscriptionName(forPlanType: tier)
            ?? UsageSnapshot.subscriptionName(forPlanType: organizationType)
    }
}

/// The signed-in accounts, shared so a view shows them from its first frame instead of
/// popping the account switch in after a scan.
@MainActor
final class ClaudeAccountStore: ObservableObject {
    static let shared = ClaudeAccountStore()

    @Published private(set) var options = ClaudeAccountOption.discover()

    /// Picks up accounts signed in or out since the last scan.
    func reload() async {
        let options = await Task.detached(priority: .userInitiated) {
            ClaudeAccountOption.discover()
        }.value
        if options != self.options {
            self.options = options
        }
    }
}
