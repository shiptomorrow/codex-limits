import Foundation

enum UsageProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    static let preferenceKey = "usageProvider"

    static var current: UsageProvider {
        UserDefaults.standard.string(forKey: preferenceKey)
            .flatMap(UsageProvider.init(rawValue:)) ?? .codex
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    /// Limit ID of the provider's main usage limit in `UsageSnapshot`.
    var mainLimitID: String { rawValue }

    var supportsRemoteSessions: Bool { self == .codex }

    /// Codex keeps the original, unsuffixed storage so existing history survives.
    func storageKey(_ base: String) -> String {
        self == .codex ? base : "\(base)-\(rawValue)"
    }
}

@MainActor
protocol UsageClient: AnyObject {
    func fetch() async throws -> UsageSnapshot
    func shutdown()
}

extension CodexClient: UsageClient {}
