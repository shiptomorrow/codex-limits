import Foundation

enum ClaudeActivityReader {
    static func loadIntervals(
        since: Date, now: Date, includesSubagents: Bool = false
    ) async throws -> [ActivityInterval] {
        let environmentRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        let claudeRoot = environmentRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let cache = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent("ActivityCache", isDirectory: true)
            .appendingPathComponent("claude-events-v1.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("codex-limits-claude-events-v1.json")
        return try await loadIntervals(
            since: since,
            now: now,
            projectsRoot: claudeRoot.appendingPathComponent("projects", isDirectory: true),
            cacheURL: cache,
            includesSubagents: includesSubagents
        )
    }

    static func loadIntervals(
        since: Date,
        now: Date,
        projectsRoot: URL,
        cacheURL: URL,
        includesSubagents: Bool = false
    ) async throws -> [ActivityInterval] {
        try await Task.detached(priority: .utility) {
            try ClaudeActivityCache(projectsRoot: projectsRoot, cacheURL: cacheURL)
                .loadIntervals(since: since, now: now, includesSubagents: includesSubagents)
        }.value
    }
}

/// Reconstructs active Claude Code runtime from session transcripts.
///
/// A turn runs from a user prompt through the last assistant message or tool
/// result before the next prompt. Gaps longer than the idle gap inside a turn,
/// such as permission prompts, are not counted.
struct ClaudeActivityCache {
    private struct Store: Codable {
        let version: Int
        var files: [String: Entry]
    }

    private struct Entry: Codable {
        var observedSize: Int64
        var modificationTime: TimeInterval?
        var parsedOffset: Int64
        var prefixGuard: Data
        var events: [Event]
    }

    struct Event: Codable, Equatable {
        let date: Date
        let isPrompt: Bool
        let isSidechain: Bool
    }

    private static let formatVersion = 1
    private static let guardLength = 1_024
    private static let maximumSessionFileSize: Int64 = 200_000_000
    private static let retention: TimeInterval = 45 * 86_400

    let projectsRoot: URL
    let cacheURL: URL

    func loadIntervals(since: Date, now: Date, includesSubagents: Bool = false) throws -> [ActivityInterval] {
        var store = loadStore()
        var changed = false

        let files = sessionFiles(modifiedSince: since)
        for file in files {
            var cached = store.files[file.key]
            if let entry = cached {
                if file.size == entry.observedSize && file.modificationTime == entry.modificationTime {
                    continue
                }
                let canAppend = file.size >= entry.parsedOffset
                    && (try? read(file: file.url, count: Int64(entry.prefixGuard.count))) == entry.prefixGuard
                if !canAppend {
                    cached = nil
                }
            }

            var entry = cached ?? Entry(
                observedSize: 0,
                modificationTime: nil,
                parsedOffset: 0,
                prefixGuard: Data(),
                events: []
            )
            let update = try parse(file: file.url, from: entry.parsedOffset)
            entry.events += update.events
            entry.parsedOffset += update.consumedBytes
            entry.observedSize = file.size
            entry.modificationTime = file.modificationTime
            entry.prefixGuard = try read(
                file: file.url,
                count: min(Int64(Self.guardLength), entry.parsedOffset)
            )
            store.files[file.key] = entry
            changed = true
        }

        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        let expired = store.files.filter { ($0.value.modificationTime ?? 0) < cutoff }.keys
        if !expired.isEmpty {
            expired.forEach { store.files.removeValue(forKey: $0) }
            changed = true
        }
        if changed {
            try save(store)
        }

        return files.flatMap { file -> [ActivityInterval] in
            guard let entry = store.files[file.key] else { return [] }
            let isSubagentFile = file.key.contains("/subagents/")
            return [false, true].flatMap { sidechain -> [ActivityInterval] in
                let isSubagent = isSubagentFile || sidechain
                guard includesSubagents || !isSubagent else { return [] }
                let subagentID = isSubagent
                    ? "local:claude:\(file.key)\(sidechain && !isSubagentFile ? ":sidechain" : "")"
                    : nil
                return Self.intervals(from: entry.events.filter { $0.isSidechain == sidechain })
                    .map { ActivityInterval(start: $0.start, end: $0.end, subagentID: subagentID) }
            }
        }
        .filter { $0.end >= since && $0.start <= now }
    }

    static func intervals(from events: [Event]) -> [(start: Date, end: Date)] {
        var result: [(start: Date, end: Date)] = []
        var segment: (start: Date, end: Date)?

        func close() {
            if let segment, segment.end > segment.start {
                result.append(segment)
            }
            segment = nil
        }

        for event in events {
            if event.isPrompt {
                close()
                segment = (event.date, event.date)
            } else if let current = segment,
                      event.date.timeIntervalSince(current.end) <= WeeklyPaceCalculator.idleGap {
                segment = (current.start, max(current.end, event.date))
            } else {
                // Long waits inside a turn are usually permission prompts.
                close()
                segment = (event.date, event.date)
            }
        }
        close()
        return result
    }

    static func event(from line: Data, formatter: ISO8601DateFormatter) -> Event? {
        guard line.range(of: Data("\"user\"".utf8)) != nil
                || line.range(of: Data("\"assistant\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              type == "user" || type == "assistant",
              object["isMeta"] as? Bool != true,
              let timestamp = object["timestamp"] as? String,
              let date = formatter.date(from: timestamp) else { return nil }

        var isPrompt = false
        if type == "user", object["isCompactSummary"] as? Bool != true {
            let content = (object["message"] as? [String: Any])?["content"]
            if content is String {
                isPrompt = true
            } else if let blocks = content as? [[String: Any]] {
                isPrompt = !blocks.contains { $0["type"] as? String == "tool_result" }
            }
        }
        return Event(
            date: date,
            isPrompt: isPrompt,
            isSidechain: object["isSidechain"] as? Bool == true
        )
    }

    private func parse(file: URL, from offset: Int64) throws -> (events: [Event], consumedBytes: Int64) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var events: [Event] = []
        var lineStart = data.startIndex
        var consumed = 0
        for index in data.indices where data[index] == 0x0A {
            if let event = Self.event(from: data[lineStart ..< index], formatter: formatter) {
                events.append(event)
            }
            lineStart = data.index(after: index)
            consumed = data.distance(from: data.startIndex, to: lineStart)
        }
        return (events, Int64(consumed))
    }

    private func sessionFiles(
        modifiedSince since: Date
    ) -> [(url: URL, key: String, size: Int64, modificationTime: TimeInterval?)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let prefix = projectsRoot.standardizedFileURL.path + "/"
        var files: [(url: URL, key: String, size: Int64, modificationTime: TimeInterval?)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= since else { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size <= Self.maximumSessionFileSize else { continue }
            let path = url.standardizedFileURL.path
            files.append((
                url,
                path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path,
                size,
                modified.timeIntervalSince1970
            ))
        }
        return files.sorted { $0.key < $1.key }
    }

    private func read(file: URL, count: Int64) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: Int(count)) ?? Data()
    }

    private func loadStore() -> Store {
        guard let data = try? Data(contentsOf: cacheURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Self.formatVersion else {
            return Store(version: Self.formatVersion, files: [:])
        }
        return store
    }

    private func save(_ store: Store) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(store).write(to: cacheURL, options: .atomic)
    }
}
