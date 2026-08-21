import Darwin
import Foundation

enum SystemSSHProfiles {
    static func load(from configURL: URL? = nil) -> [String] {
        let configURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        var visited: Set<String> = []
        var profiles: Set<String> = []
        parse(
            configURL.standardizedFileURL,
            includeBase: configURL.deletingLastPathComponent().standardizedFileURL,
            visited: &visited,
            profiles: &profiles
        )
        return profiles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func parse(
        _ url: URL,
        includeBase: URL,
        visited: inout Set<String>,
        profiles: inout Set<String>
    ) {
        let path = url.resolvingSymlinksInPath().path
        guard visited.insert(path).inserted,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = withoutComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = parts.first?.lowercased() else { continue }

            if keyword == "host" {
                for rawAlias in parts.dropFirst() {
                    let alias = rawAlias.trimmingCharacters(
                        in: CharacterSet(charactersIn: "\"'")
                    )
                    if isConcreteAlias(alias) {
                        profiles.insert(alias)
                    }
                }
            } else if keyword == "include" {
                for pattern in parts.dropFirst() {
                    for includedURL in expand(pattern, relativeTo: includeBase) {
                        parse(
                            includedURL,
                            includeBase: includeBase,
                            visited: &visited,
                            profiles: &profiles
                        )
                    }
                }
            }
        }
    }

    private static func withoutComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "#", !quoted {
                return String(line[..<index])
            }
        }
        return line
    }

    static func isConcreteAlias(_ alias: String) -> Bool {
        !alias.isEmpty
            && !alias.hasPrefix("-")
            && !alias.contains(where: { "*?!".contains($0) })
    }

    private static func expand(_ rawPattern: String, relativeTo base: URL) -> [URL] {
        let unquoted = rawPattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let expanded = NSString(string: unquoted).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
        let components = NSString(string: expanded).pathComponents.filter { $0 != "/" }
        var candidates = [absolute ? URL(fileURLWithPath: "/") : base]

        for component in components {
            if component.contains(where: { "*?[".contains($0) }) {
                candidates = candidates.flatMap { directory in
                    let children = (try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    return children.filter {
                        fnmatch(component, $0.lastPathComponent, 0) == 0
                    }
                }
            } else {
                candidates = candidates.map { $0.appendingPathComponent(component) }
            }
        }
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }
}

struct RemoteCodexActivityResult: Sendable {
    let intervals: [ActivityInterval]
    let errors: [String]
}

enum RemoteCodexActivityReader {
    private struct ProfileResult: Sendable {
        let profile: String
        let intervals: [ActivityInterval]
        let error: String?
    }

    static func loadIntervals(
        profiles: [String],
        since: Date,
        now: Date
    ) async -> RemoteCodexActivityResult {
        let results = await withTaskGroup(of: ProfileResult.self) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        return ProfileResult(
                            profile: profile,
                            intervals: try await loadIntervals(
                                profile: profile,
                                since: since,
                                now: now
                            ),
                            error: nil
                        )
                    } catch {
                        return ProfileResult(
                            profile: profile,
                            intervals: [],
                            error: "\(profile): \(error.localizedDescription)"
                        )
                    }
                }
            }
            var values: [ProfileResult] = []
            for await result in group {
                values.append(result)
            }
            return values
        }

        return RemoteCodexActivityResult(
            intervals: results.flatMap(\.intervals),
            errors: results.compactMap(\.error).sorted()
        )
    }

    private static func loadIntervals(
        profile: String,
        since: Date,
        now: Date
    ) async throws -> [ActivityInterval] {
        guard SystemSSHProfiles.isConcreteAlias(profile) else {
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid SSH profile name"]
            )
        }
        return try await Task.detached(priority: .utility) {
            let snapshotRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexLimitsRemote-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: snapshotRoot,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: snapshotRoot) }

            try downloadSnapshot(
                profile: profile,
                since: since,
                now: now,
                to: snapshotRoot
            )

            let codexRoot = snapshotRoot.appendingPathComponent(".codex", isDirectory: true)
            let cacheURL = applicationSupportDirectory()
                .appendingPathComponent("RemoteActivityCache", isDirectory: true)
                .appendingPathComponent(safeIdentifier(profile), isDirectory: true)
                .appendingPathComponent("events-v2.json")
            return try CodexActivityCache(
                sessionsRoot: codexRoot.appendingPathComponent("sessions", isDirectory: true),
                archivedSessionsRoot: codexRoot.appendingPathComponent(
                    "archived_sessions",
                    isDirectory: true
                ),
                cacheURL: cacheURL
            ).loadIntervals(since: since, now: now)
        }.value
    }

    private static func downloadSnapshot(
        profile: String,
        since: Date,
        now: Date,
        to destination: URL
    ) throws {
        let days = max(1, Int(ceil(now.timeIntervalSince(since) / 86_400)) + 2)
        let remoteCommand = """
        set -eu
        cd "$HOME"
        list=$(mktemp)
        trap 'rm -f "$list"' EXIT HUP INT TERM
        find .codex/sessions .codex/archived_sessions -type f -name '*.jsonl' -mtime -\(days) -print 2>/dev/null >"$list" || true
        tar -cf - -T "$list"
        """

        let transfer = Pipe()
        let sshError = Pipe()
        let tarError = Pipe()
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = [
            "-n", "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            profile,
            remoteCommand
        ]
        ssh.standardInput = FileHandle.nullDevice
        ssh.standardOutput = transfer
        ssh.standardError = sshError

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", "-", "-C", destination.path]
        tar.standardInput = transfer
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = tarError

        do {
            try tar.run()
            try ssh.run()
        } catch {
            if ssh.isRunning { ssh.terminate() }
            if tar.isRunning { tar.terminate() }
            throw error
        }
        try? transfer.fileHandleForReading.close()
        try? transfer.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(15)
        while ssh.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if ssh.isRunning {
            ssh.terminate()
            tar.terminate()
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SSH session timed out"]
            )
        }
        ssh.waitUntilExit()

        while tar.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if tar.isRunning { tar.terminate() }
        tar.waitUntilExit()

        if ssh.terminationStatus != 0 {
            let detail = String(
                decoding: sshError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: Int(ssh.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "SSH connection failed" : detail]
            )
        }
        if tar.terminationStatus != 0 {
            let detail = String(
                decoding: tarError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: Int(tar.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "Couldn’t read remote sessions" : detail]
            )
        }
    }

    private static func applicationSupportDirectory() -> URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
    }

    private static func safeIdentifier(_ profile: String) -> String {
        Data(profile.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
