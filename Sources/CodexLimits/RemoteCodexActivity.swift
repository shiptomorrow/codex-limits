import Darwin
import Foundation

enum RemoteSSHPolicy {
    static let connectTimeoutSeconds = 15
    static let operationTimeout: TimeInterval = 5 * 60
    static let retryDelay: TimeInterval = 5 * 60
}

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
    private struct IntervalPayload: Decodable {
        let version: Int
        let intervals: [RemoteInterval]
    }

    private struct RemoteInterval: Decodable {
        let start: TimeInterval
        let end: TimeInterval
        let isFastMode: Bool
    }

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
            let workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexLimitsRemote-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: workDirectory) }

            return try loadRemoteIntervals(
                profile: profile,
                since: since,
                now: now,
                in: workDirectory
            )
        }.value
    }

    private static func loadRemoteIntervals(
        profile: String,
        since: Date,
        now: Date,
        in workDirectory: URL
    ) throws -> [ActivityInterval] {
        guard let scriptURL = remoteActivityScriptURL() else {
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Remote activity helper is missing"]
            )
        }
        let outputURL = workDirectory.appendingPathComponent("intervals.json")
        let errorURL = workDirectory.appendingPathComponent("ssh-error.log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let scriptInput = try FileHandle(forReadingFrom: scriptURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let sshError = try FileHandle(forWritingTo: errorURL)
        defer {
            try? scriptInput.close()
            try? output.close()
            try? sshError.close()
        }

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(RemoteSSHPolicy.connectTimeoutSeconds)",
            "-o", "ConnectionAttempts=1",
            profile,
            "python3 - \(since.timeIntervalSince1970) \(now.timeIntervalSince1970)"
        ]
        ssh.standardInput = scriptInput
        ssh.standardOutput = output
        ssh.standardError = sshError

        do {
            try ssh.run()
        } catch {
            if ssh.isRunning { ssh.terminate() }
            CodexDiagnostics.record(
                "Remote SSH launch failed for profile \(profile)",
                details: error.localizedDescription
            )
            throw error
        }

        let sshDeadline = Date().addingTimeInterval(RemoteSSHPolicy.operationTimeout)
        while ssh.isRunning, Date() < sshDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if ssh.isRunning {
            ssh.terminate()
            let error = NSError(
                domain: "CodexLimits.RemoteActivity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SSH session timed out"]
            )
            CodexDiagnostics.record(
                "Remote SSH timed out for profile \(profile)",
                details: "The remote activity request exceeded \(Int(RemoteSSHPolicy.operationTimeout)) seconds."
            )
            throw error
        }
        ssh.waitUntilExit()
        try? output.close()
        try? sshError.close()

        if ssh.terminationStatus != 0 {
            let detail = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            CodexDiagnostics.record(
                "Remote SSH failed for profile \(profile) with exit code \(ssh.terminationStatus)",
                details: detail.isEmpty ? "SSH produced no error output." : detail
            )
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: Int(ssh.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "SSH connection failed" : detail]
            )
        }

        do {
            let payload = try JSONDecoder().decode(
                IntervalPayload.self,
                from: Data(contentsOf: outputURL)
            )
            guard payload.version == 1 else {
                throw NSError(
                    domain: "CodexLimits.RemoteActivity",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported remote activity response"]
                )
            }
            return payload.intervals.map {
                ActivityInterval(
                    start: Date(timeIntervalSince1970: $0.start),
                    end: Date(timeIntervalSince1970: $0.end),
                    isFastMode: $0.isFastMode
                )
            }
        } catch {
            let response = ((try? String(contentsOf: outputURL, encoding: .utf8)) ?? "")
            CodexDiagnostics.record(
                "Remote activity response could not be decoded for profile \(profile)",
                details: "\(error.localizedDescription)\n\(response)"
            )
            throw NSError(
                domain: "CodexLimits.RemoteActivity",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Couldn’t read remote activity response: \(error.localizedDescription)"]
            )
        }
    }

    private static func remoteActivityScriptURL() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "remote-activity",
            withExtension: "py"
        ) {
            return bundled
        }
        let sourceTree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/remote-activity.py")
        return FileManager.default.fileExists(atPath: sourceTree.path) ? sourceTree : nil
    }
}
