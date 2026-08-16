import Foundation
import OSLog

enum CodexDiagnostics {
    private static let maximumLogSize = 1_000_000
    private static let maximumDetailLength = 32_000
    private static let lock = NSLock()
    private static let logger = Logger(
        subsystem: "com.github.thrr87.CodexLimits",
        category: "CodexClient"
    )

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Codex Limits", isDirectory: true)
        .appendingPathComponent("codex-client.log")

    static func record(_ event: String, details: String? = nil) {
        logger.error(
            "\(event, privacy: .public); diagnostics: \(logURL.path, privacy: .public)"
        )

        lock.lock()
        defer { lock.unlock() }

        do {
            let fileManager = FileManager.default
            let directory = logURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded(fileManager: fileManager)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ?? "development"
            var entry = "[\(formatter.string(from: Date()))] Codex Limits \(version): \(event)"
            if let details, !details.isEmpty {
                entry += "\n" + String(details.prefix(maximumDetailLength))
            }
            entry += "\n\n"

            if !fileManager.fileExists(atPath: logURL.path) {
                _ = fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
            try handle.close()
        } catch {
            logger.error(
                "Could not write Codex diagnostics: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func rotateIfNeeded(fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: logURL.path) else { return }
        guard let size = try fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int,
              size >= maximumLogSize else { return }

        let previousURL = logURL.deletingPathExtension().appendingPathExtension("previous.log")
        if fileManager.fileExists(atPath: previousURL.path) {
            try fileManager.removeItem(at: previousURL)
        }
        try fileManager.moveItem(at: logURL, to: previousURL)
    }
}
