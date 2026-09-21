import Foundation

struct CodexActivityCache {
    private struct SessionFile {
        let url: URL
        let cacheKey: String

        var identity: String { url.lastPathComponent }
    }

    private struct Store: Codable {
        let version: Int
        var corruptionMessage: String?
        var files: [String: Entry]
    }

    private struct Entry: Codable {
        var observedSize: Int64
        var modificationTime: TimeInterval?
        var parsedOffset: Int64
        var prefixGuard: Data
        var suffixGuard: Data
        var events: Events
    }

    private struct Events: Codable {
        var starts: [TaskStart] = []
        var completions: [TaskCompletion] = []
        var tokenTimes: [Date] = []
        var modeChanges: [ModeChange] = []
        var approvalCalls: [ApprovalCall] = []
        var toolResults: [ToolResult] = []
        var isSubagent: Bool?

        mutating func append(_ other: Events) {
            starts += other.starts
            completions += other.completions
            tokenTimes += other.tokenTimes
            modeChanges += other.modeChanges
            approvalCalls += other.approvalCalls
            toolResults += other.toolResults
            if let isSubagent = other.isSubagent {
                self.isSubagent = isSubagent
            }
        }
    }

    private struct TaskStart: Codable {
        let turnID: String
        let date: Date
    }

    private struct TaskCompletion: Codable {
        let turnID: String
        let start: Date
        let end: Date
    }

    private struct ModeChange: Codable {
        let date: Date
        let isFastMode: Bool
    }

    private struct ApprovalCall: Codable {
        let callID: String
        let date: Date
    }

    private struct ToolResult: Codable {
        let callID: String
        let date: Date
        let executionDuration: TimeInterval
    }

    private enum ParsedLine {
        case irrelevant
        case event(Events)
    }

    // Reparse older caches, which omitted interruptions and approval timing.
    private static let formatVersion = 5
    private static let guardLength = 4_096
    private static let maximumSessionFileSize = 50_000_000

    let sessionsRoot: URL
    let archivedSessionsRoot: URL?
    let cacheURL: URL

    func loadIntervals(since: Date, now: Date) throws -> [ActivityInterval] {
        var store = loadStore()
        var changed = store.corruptionMessage != nil
        if changed {
            // Older versions persisted a failure after any session rewrite.
            store = Store(version: Self.formatVersion, corruptionMessage: nil, files: [:])
        }

        let files = sessionFiles(since: since, now: now)

        for file in files {
            let key = file.cacheKey
            let values = try file.url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey
            ])
            let size = Int64(values.fileSize ?? 0)
            let modificationTime = values.contentModificationDate?.timeIntervalSince1970

            var cached = store.files[key]
            if let entry = cached {
                if size == entry.observedSize && modificationTime == entry.modificationTime {
                    continue
                }
                let canAppend = try size > entry.observedSize && guardsMatch(entry, file: file.url)
                if !canAppend {
                    // Reparse rewritten files instead of appending to stale events.
                    cached = nil
                }
            }

            if var entry = cached {
                let update = try parse(file: file.url, from: entry.parsedOffset)
                entry.events.append(update.events)
                entry.parsedOffset += update.consumedBytes
                entry.observedSize = size
                entry.modificationTime = modificationTime
                entry.prefixGuard = try prefixGuard(file: file.url, through: entry.parsedOffset)
                entry.suffixGuard = try suffixGuard(file: file.url, through: entry.parsedOffset)
                store.files[key] = entry
                changed = true
            } else {
                let update = try parse(file: file.url, from: 0)
                let entry = Entry(
                    observedSize: size,
                    modificationTime: modificationTime,
                    parsedOffset: update.consumedBytes,
                    prefixGuard: try prefixGuard(file: file.url, through: update.consumedBytes),
                    suffixGuard: try suffixGuard(file: file.url, through: update.consumedBytes),
                    events: update.events
                )
                store.files[key] = entry
                changed = true
            }
        }

        if changed {
            try save(store)
        }
        return intervals(
            from: files.compactMap { store.files[$0.cacheKey] },
            since: since,
            now: now
        )
    }

    private func loadStore() -> Store {
        guard let data = try? Data(contentsOf: cacheURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Self.formatVersion else {
            return Store(version: Self.formatVersion, corruptionMessage: nil, files: [:])
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

    private func parse(file: URL, from offset: Int64) throws -> (events: Events, consumedBytes: Int64) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()
        var events = Events()
        var lineStart = data.startIndex
        var consumed = 0

        for index in data.indices where data[index] == 0x0A {
            var line = Data(data[lineStart ..< index])
            if line.last == 0x0D {
                line.removeLast()
            }
            switch parseLine(line) {
            case .irrelevant:
                break
            case let .event(parsed):
                events.append(parsed)
            }
            lineStart = data.index(after: index)
            consumed = data.distance(from: data.startIndex, to: lineStart)
        }
        return (events, Int64(consumed))
    }

    private func parseLine(_ line: Data) -> ParsedLine {
        if line.range(of: Data("\"response_item\"".utf8)) != nil,
           let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           object["type"] as? String == "response_item" {
            return parseToolTiming(object)
        }
        let isSessionMetadata = line.range(of: Data("\"session_meta\"".utf8)) != nil
        guard isSessionMetadata || line.range(of: Data("\"event_msg\"".utf8)) != nil else {
            return .irrelevant
        }
        if isSessionMetadata {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else {
                return .irrelevant
            }
            var events = Events()
            let source = payload["source"] as? [String: Any]
            events.isSubagent = payload["thread_source"] as? String == "subagent"
                || source?["subagent"] != nil
            return .event(events)
        }

        let markers = [
            "\"task_started\"",
            "\"task_complete\"",
            "\"turn_aborted\"",
            "\"token_count\"",
            "\"thread_settings_applied\""
        ]
        guard markers.contains(where: { line.range(of: Data($0.utf8)) != nil }) else {
            return .irrelevant
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return .irrelevant
        }

        var events = Events()
        switch type {
        case "thread_settings_applied":
            guard let settings = payload["thread_settings"] as? [String: Any],
                  let serviceTier = settings["service_tier"] as? String,
                  let timestamp = object["timestamp"] as? String,
                  let date = Self.timestampDate(timestamp) else { return .irrelevant }
            events.modeChanges.append(ModeChange(
                date: date,
                isFastMode: serviceTier == "fast" || serviceTier == "priority"
            ))
        case "task_started":
            guard let turnID = payload["turn_id"] as? String,
                  let startedAt = Self.seconds(payload["started_at"]) else {
                return .irrelevant
            }
            events.starts.append(TaskStart(
                turnID: turnID,
                date: Date(timeIntervalSince1970: startedAt)
            ))
        case "task_complete", "turn_aborted":
            guard let turnID = payload["turn_id"] as? String,
                  let startedAt = Self.seconds(payload["started_at"]),
                  let completedAt = Self.seconds(payload["completed_at"]) else {
                return .irrelevant
            }
            events.completions.append(TaskCompletion(
                turnID: turnID,
                start: Date(timeIntervalSince1970: startedAt),
                end: Date(timeIntervalSince1970: completedAt)
            ))
        case "token_count":
            guard let timestamp = object["timestamp"] as? String,
                  let date = Self.timestampDate(timestamp) else { return .irrelevant }
            events.tokenTimes.append(date)
        default:
            return .irrelevant
        }
        return .event(events)
    }

    private func parseToolTiming(_ object: [String: Any]) -> ParsedLine {
        guard let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String,
              let callID = payload["call_id"] as? String,
              let timestamp = object["timestamp"] as? String,
              let date = Self.timestampDate(timestamp) else { return .irrelevant }
        var events = Events()
        if type == "custom_tool_call" || type == "function_call" {
            let input = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
            guard input.range(
                of: #"["']?sandbox_permissions["']?\s*:\s*["']require_escalated["']"#,
                options: .regularExpression
            ) != nil else { return .irrelevant }
            events.approvalCalls.append(ApprovalCall(callID: callID, date: date))
        } else if type == "custom_tool_call_output" || type == "function_call_output" {
            guard let output = payload["output"] as? String,
                  let duration = Self.scriptExecutionDuration(output) else { return .irrelevant }
            events.toolResults.append(ToolResult(
                callID: callID, date: date, executionDuration: duration
            ))
        } else {
            return .irrelevant
        }
        return .event(events)
    }

    private static func scriptExecutionDuration(_ output: String) -> TimeInterval? {
        // Only trust the outer tool runner's timing, never numbers inside tool output.
        let pattern = #"^Script (?:completed|running[^\n]*)\nWall time ([0-9.]+) seconds\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output),
              let seconds = Double(output[range]), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func excludingApprovalWaits(
        _ interval: ActivityInterval, events: Events
    ) -> [ActivityInterval] {
        var result = [interval]
        for call in events.approvalCalls {
            guard let output = events.toolResults.first(where: { $0.callID == call.callID }) else { continue }
            let resumedAt = output.date.addingTimeInterval(-output.executionDuration)
            // Preserve reported execution time. Only remove long, unaccounted waits
            // on calls that explicitly requested approval; long running work stays intact.
            guard resumedAt.timeIntervalSince(call.date) > WeeklyPaceCalculator.idleGap else { continue }
            result = result.flatMap { segment in
                guard call.date < segment.end, resumedAt > segment.start else { return [segment] }
                var pieces: [ActivityInterval] = []
                if segment.start < call.date {
                    pieces.append(ActivityInterval(start: segment.start, end: call.date))
                }
                if segment.end > resumedAt {
                    pieces.append(ActivityInterval(start: resumedAt, end: segment.end))
                }
                return pieces
            }
        }
        return result
    }

    private func intervals(from entries: [Entry], since: Date, now: Date) -> [ActivityInterval] {
        let entries = entries.filter { $0.events.isSubagent != true }
        var starts: [String: (date: Date, entry: Int)] = [:]
        var completedIDs: Set<String> = []
        var completed: [(interval: ActivityInterval, entry: Int)] = []
        let allModeChanges = entries.flatMap(\.events.modeChanges)

        for (entryIndex, entry) in entries.enumerated() {
            for start in entry.events.starts {
                starts[start.turnID] = (start.date, entryIndex)
            }
            for completion in entry.events.completions {
                completedIDs.insert(completion.turnID)
                completed.append((
                    ActivityInterval(start: completion.start, end: completion.end),
                    entryIndex
                ))
            }
        }

        var intervals = completed.flatMap { completion in
            excludingApprovalWaits(
                completion.interval, events: entries[completion.entry].events
            ).flatMap {
                CodexActivityReader.split(
                    $0,
                    at: entries[completion.entry].events.modeChanges.map { ($0.date, $0.isFastMode) },
                    inheriting: allModeChanges.map { ($0.date, $0.isFastMode) }
                )
            }
        }
        for (turnID, start) in starts where !completedIDs.contains(turnID) {
            let entry = entries[start.entry]
            let end = entry.events.tokenTimes
                .filter { $0 >= start.date && $0 <= now }
                .max() ?? start.date
            if end > start.date {
                intervals += excludingApprovalWaits(
                    ActivityInterval(start: start.date, end: end), events: entry.events
                ).flatMap {
                    CodexActivityReader.split(
                        $0,
                        at: entry.events.modeChanges.map { ($0.date, $0.isFastMode) },
                        inheriting: allModeChanges.map { ($0.date, $0.isFastMode) }
                    )
                }
            }
        }
        return intervals.filter { $0.end >= since && $0.start <= now }
    }

    private func guardsMatch(_ entry: Entry, file: URL) throws -> Bool {
        try prefixGuard(file: file, through: entry.parsedOffset) == entry.prefixGuard
            && suffixGuard(file: file, through: entry.parsedOffset) == entry.suffixGuard
    }

    private func prefixGuard(file: URL, through offset: Int64) throws -> Data {
        try read(file: file, offset: 0, count: min(Int64(Self.guardLength), offset))
    }

    private func suffixGuard(file: URL, through offset: Int64) throws -> Data {
        let count = min(Int64(Self.guardLength), offset)
        return try read(file: file, offset: offset - count, count: count)
    }

    private func read(file: URL, offset: Int64, count: Int64) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(count)) ?? Data()
    }

    private func sessionFiles(since: Date, now: Date) -> [SessionFile] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var day = calendar.startOfDay(for: since.addingTimeInterval(-86_400))
        let finalDay = calendar.startOfDay(for: now.addingTimeInterval(86_400))
        var activeFiles: [SessionFile] = []
        var includedDayNames: Set<String> = []

        while day <= finalDay {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let dayName = String(
                format: "%04d-%02d-%02d",
                components.year!,
                components.month!,
                components.day!
            )
            includedDayNames.insert(dayName)
            let directory = sessionsRoot
                .appendingPathComponent(String(format: "%04d", components.year!))
                .appendingPathComponent(String(format: "%02d", components.month!))
                .appendingPathComponent(String(format: "%02d", components.day!))
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                activeFiles += contents.compactMap { url in
                    guard isReadableSessionFile(url) else { return nil }
                    return SessionFile(
                        url: url,
                        cacheKey: relativePath(for: url)
                    )
                }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        let archivedFiles = archivedSessionFiles(includedDayNames: includedDayNames)
        var filesByIdentity = Dictionary(
            uniqueKeysWithValues: archivedFiles.map { ($0.identity, $0) }
        )
        for file in activeFiles {
            filesByIdentity[file.identity] = file
        }
        return filesByIdentity.values.sorted { $0.cacheKey < $1.cacheKey }
    }

    private func archivedSessionFiles(includedDayNames: Set<String>) -> [SessionFile] {
        guard let archivedSessionsRoot,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: archivedSessionsRoot,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return contents.compactMap { url in
            guard isReadableSessionFile(url),
                  includedDayNames.contains(where: {
                    url.lastPathComponent.hasPrefix("rollout-\($0)T")
                  }) else {
                return nil
            }
            return SessionFile(
                url: url,
                cacheKey: "archived/\(url.lastPathComponent)"
            )
        }
    }

    private func isReadableSessionFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl"
            && ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                <= Self.maximumSessionFileSize
    }

    private func relativePath(for file: URL) -> String {
        let prefix = sessionsRoot.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private static func timestampDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
