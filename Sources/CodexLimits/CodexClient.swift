import Foundation

enum CodexClientError: LocalizedError, Equatable {
    case cliNotFound
    case invalidResponse
    case mainLimitMissing
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "Codex CLI was not found. Install it, sign in, and try again."
        case .invalidResponse:
            "Codex returned data this app could not read. Update Codex CLI and try again."
        case .mainLimitMissing:
            "Codex did not return a usable limit. Make sure Codex CLI is signed in."
        case .timedOut:
            "Codex took too long to respond. Try refreshing again."
        }
    }
}

private enum CodexConnectionError: Error {
    case disconnected
    case timedOut
}

@MainActor
final class CodexClient {
    private final class Connection: @unchecked Sendable {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        let errorOutput: FileHandle
        let executableIdentity: ExecutableIdentity
        let startedAt: Date

        init(
            process: Process,
            input: FileHandle,
            output: FileHandle,
            errorOutput: FileHandle,
            executableIdentity: ExecutableIdentity,
            startedAt: Date
        ) {
            self.process = process
            self.input = input
            self.output = output
            self.errorOutput = errorOutput
            self.executableIdentity = executableIdentity
            self.startedAt = startedAt
        }
    }

    private struct ExecutableIdentity: Equatable {
        let resolvedPath: String
        let modificationDate: Date?
        let fileSize: Int?
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private static let defaultExecutablePaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codex").path
    ]

    private let executablePaths: [String]
    private let requestTimeoutNanoseconds: UInt64
    private let maximumConnectionAge: TimeInterval
    private let now: () -> Date
    private var connection: Connection?
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID = 1

    init(
        executablePaths: [String]? = nil,
        requestTimeoutNanoseconds: UInt64 = 15_000_000_000,
        maximumConnectionAge: TimeInterval = 5 * 60 * 60,
        now: @escaping () -> Date = { Date() }
    ) {
        self.executablePaths = executablePaths ?? Self.defaultExecutablePaths
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
        self.maximumConnectionAge = maximumConnectionAge
        self.now = now
    }

    func fetch() async throws -> UsageSnapshot {
        for attempt in 0...1 {
            do {
                return try await fetchOnce()
            } catch let error as CodexConnectionError {
                stopConnection(error: error)
                if attempt == 0 { continue }
                switch error {
                case .timedOut:
                    throw CodexClientError.timedOut
                case .disconnected:
                    throw CodexClientError.invalidResponse
                }
            }
        }
        throw CodexClientError.invalidResponse
    }

    func shutdown() {
        stopConnection(error: CancellationError())
    }

    private func fetchOnce() async throws -> UsageSnapshot {
        let connection = try await readyConnection()
        let fetchedAt = Date()

        async let rateLimitsResponse = request(
            method: "account/rateLimits/read",
            on: connection
        )
        async let usageResponse = request(
            method: "account/usage/read",
            on: connection
        )

        return try await Self.decode(
            rateLimitsResponse: rateLimitsResponse,
            usageResponse: usageResponse,
            fetchedAt: fetchedAt
        )
    }

    private func readyConnection() async throws -> Connection {
        guard let executable = currentExecutable() else {
            stopConnection(error: CodexConnectionError.disconnected)
            throw CodexClientError.cliNotFound
        }

        if let connection {
            let connectionAge = max(0, now().timeIntervalSince(connection.startedAt))
            if connection.executableIdentity == executable.identity,
               connection.process.isRunning,
               connectionAge < maximumConnectionAge {
                return connection
            }
            stopConnection(error: CodexConnectionError.disconnected)
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = executable.url
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            CodexDiagnostics.record(
                "Could not start Codex CLI app-server",
                details: "Executable: \(executable.url.path)\nError: \(error)"
            )
            throw CodexConnectionError.disconnected
        }

        let connection = Connection(
            process: process,
            input: input.fileHandleForWriting,
            output: output.fileHandleForReading,
            errorOutput: errorOutput.fileHandleForReading,
            executableIdentity: executable.identity,
            startedAt: now()
        )
        self.connection = connection
        startReader(for: connection)
        startErrorReader(for: connection)
        process.terminationHandler = { [weak self, weak connection] _ in
            guard let connection else { return }
            Task { @MainActor in
                self?.connectionEnded(connection)
            }
        }

        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
            _ = try await request(
                method: "initialize",
                params: #"{"clientInfo":{"name":"codex-limits","title":"Codex Limits","version":"\#(version)"},"capabilities":{"experimentalApi":true}}"#,
                on: connection
            )
            try write(#"{"method":"initialized"}"#, to: connection.input)
            return connection
        } catch {
            stopConnection(error: error)
            throw error
        }
    }

    private func currentExecutable() -> (url: URL, identity: ExecutableIdentity)? {
        guard let path = executablePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ])
        return (
            url,
            ExecutableIdentity(
                resolvedPath: url.path,
                modificationDate: values?.contentModificationDate,
                fileSize: values?.fileSize
            )
        )
    }

    private func startReader(for connection: Connection) {
        let output = connection.output
        DispatchQueue.global(qos: .utility).async { [weak self, weak connection] in
            guard let connection else { return }
            var buffer = Data()
            while true {
                let chunk = output.availableData
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    var line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.last == 0x0D { line.removeLast() }
                    let completeLine = line
                    let delivered = DispatchSemaphore(value: 0)
                    Task { @MainActor [weak self, weak connection] in
                        if let connection {
                            self?.receive(completeLine, from: connection)
                        }
                        delivered.signal()
                    }
                    delivered.wait()
                }
            }
            if !buffer.isEmpty {
                let remaining = buffer
                let delivered = DispatchSemaphore(value: 0)
                Task { @MainActor [weak self, weak connection] in
                    if let connection {
                        self?.receive(remaining, from: connection)
                    }
                    delivered.signal()
                }
                delivered.wait()
            }
            Task { @MainActor [weak self, weak connection] in
                if let connection {
                    self?.connectionEnded(connection)
                }
            }
        }
    }

    private func startErrorReader(for connection: Connection) {
        let errorOutput = connection.errorOutput
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = errorOutput.availableData
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    var line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if line.last == 0x0D { line.removeLast() }
                    guard !line.isEmpty else { continue }
                    CodexDiagnostics.record(
                        "Codex CLI stderr",
                        details: String(decoding: line, as: UTF8.self)
                    )
                }
            }
            if !buffer.isEmpty {
                CodexDiagnostics.record(
                    "Codex CLI stderr",
                    details: String(decoding: buffer, as: UTF8.self)
                )
            }
        }
    }

    private func request(
        method: String,
        params: String? = nil,
        on connection: Connection
    ) async throws -> Data {
        guard self.connection === connection, connection.process.isRunning else {
            throw CodexConnectionError.disconnected
        }

        let id = nextRequestID
        nextRequestID += 1
        let message = params.map {
            #"{"id":\#(id),"method":"\#(method)","params":\#($0)}"#
        } ?? #"{"id":\#(id),"method":"\#(method)"}"#

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = PendingRequest(continuation: continuation)
                let timeoutTask = Task { @MainActor [weak self, weak connection] in
                    guard let self, let connection else { return }
                    try? await Task.sleep(nanoseconds: self.requestTimeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    CodexDiagnostics.record(
                        "Codex app-server request timed out",
                        details: "Method: \(method)\nRequest ID: \(id)"
                    )
                    self.failConnection(connection, error: CodexConnectionError.timedOut)
                }
                pendingRequests[id]?.timeoutTask = timeoutTask

                do {
                    try write(message, to: connection.input)
                } catch {
                    failConnection(connection, error: CodexConnectionError.disconnected)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id)
            }
        }
    }

    private func receive(_ data: Data, from connection: Connection) {
        guard self.connection === connection else { return }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CodexClientError.invalidResponse
            }
            object = decoded
        } catch {
            CodexDiagnostics.record(
                "Codex app-server emitted malformed JSON",
                details: String(decoding: data, as: UTF8.self)
            )
            failConnection(connection, error: CodexClientError.invalidResponse)
            return
        }

        // App-server notifications do not carry request IDs and are not responses.
        guard let id = object["id"] as? Int,
              let pending = pendingRequests.removeValue(forKey: id) else { return }

        pending.timeoutTask?.cancel()
        if object["error"] != nil {
            CodexDiagnostics.record(
                "Codex app-server returned an RPC error",
                details: String(decoding: data, as: UTF8.self)
            )
            pending.continuation.resume(throwing: CodexClientError.invalidResponse)
        } else {
            pending.continuation.resume(returning: data)
        }
    }

    private func cancelRequest(_ id: Int) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask?.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func connectionEnded(_ connection: Connection) {
        guard self.connection === connection else { return }
        let status = connection.process.isRunning
            ? "unknown"
            : String(connection.process.terminationStatus)
        CodexDiagnostics.record(
            "Codex CLI app-server disconnected unexpectedly",
            details: "Termination status: \(status)"
        )
        failConnection(connection, error: CodexConnectionError.disconnected)
    }

    private func failConnection(_ connection: Connection, error: Error) {
        guard self.connection === connection else { return }
        stopConnection(error: error)
    }

    private func stopConnection(error: Error) {
        let connection = self.connection
        self.connection = nil
        try? connection?.input.close()
        try? connection?.output.close()
        try? connection?.errorOutput.close()
        if connection?.process.isRunning == true {
            connection?.process.terminate()
        }

        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    nonisolated static func decode(
        rateLimitsResponse: Data,
        usageResponse: Data,
        fetchedAt: Date
    ) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        let rateResponse: RPCResponse<RateLimitsResult>
        let usage: RPCResponse<UsageResult>
        do {
            rateResponse = try decoder.decode(
                RPCResponse<RateLimitsResult>.self,
                from: rateLimitsResponse
            )
            usage = try decoder.decode(RPCResponse<UsageResult>.self, from: usageResponse)
        } catch {
            CodexDiagnostics.record(
                "Could not decode Codex app-server usage responses",
                details: "Decode error: \(error)\nRate limits response: \(String(decoding: rateLimitsResponse, as: UTF8.self))\nUsage response: \(String(decoding: usageResponse, as: UTF8.self))"
            )
            throw CodexClientError.invalidResponse
        }
        guard let rateResult = rateResponse.result,
              let usageResult = usage.result else {
            CodexDiagnostics.record(
                "Codex app-server response did not contain a result",
                details: "Rate limits response: \(String(decoding: rateLimitsResponse, as: UTF8.self))\nUsage response: \(String(decoding: usageResponse, as: UTF8.self))"
            )
            throw CodexClientError.invalidResponse
        }

        let snapshots = rateResult.rateLimitsByLimitId ?? ["codex": rateResult.rateLimits]
        let mainSnapshot = snapshots["codex"] ?? rateResult.rateLimits
        let planType = mainSnapshot.planType ?? rateResult.rateLimits.planType
        let mainWindows = windows(from: mainSnapshot)
        guard let mainWindow = mainWindows.min(by: {
            $0.remainingPercent < $1.remainingPercent
        }) else {
            throw CodexClientError.mainLimitMissing
        }

        let extraMainWindows = mainWindows
            .filter { $0 != mainWindow }
            .map {
                LimitReading(limitId: "codex", name: windowName($0.durationMinutes), window: $0)
            }
        let otherLimits = snapshots
            .filter { $0.key != "codex" }
            .compactMap { id, snapshot -> LimitReading? in
                guard let window = windows(from: snapshot).min(by: {
                    $0.remainingPercent < $1.remainingPercent
                }) else { return nil }
                return LimitReading(
                    limitId: id,
                    name: snapshot.limitName ?? id,
                    window: window
                )
            }
        let others = (extraMainWindows + otherLimits)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let tokenHistory = (usageResult.dailyUsageBuckets ?? []).compactMap { bucket -> TokenDay? in
            guard let date = dateFormatter.date(from: bucket.startDate) else { return nil }
            return TokenDay(date: date, tokens: bucket.tokens)
        }

        return UsageSnapshot(
            mainLimit: LimitReading(limitId: "codex", name: "Codex", window: mainWindow),
            otherLimits: others,
            tokenHistory: tokenHistory,
            emergencyResetCount: rateResult.rateLimitResetCredits?.availableCount ?? 0,
            nextEmergencyResetExpiration: rateResult.rateLimitResetCredits?.credits?
                .compactMap(\.expiresAt)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                .min(),
            fetchedAt: fetchedAt,
            planType: planType
        )
    }

    nonisolated private static func windows(from snapshot: RateLimitSnapshot) -> [UsageWindow] {
        [snapshot.primary, snapshot.secondary].compactMap { window in
            guard let window,
                  let resetsAt = window.resetsAt,
                  let duration = window.windowDurationMins else { return nil }
            return UsageWindow(
                remainingPercent: min(max(100 - window.usedPercent, 0), 100),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt)),
                durationMinutes: duration
            )
        }
    }

    nonisolated private static func windowName(_ minutes: Int) -> String {
        if minutes == 10_080 { return "Weekly window" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour window" }
        return "Additional window"
    }

    private func write(_ message: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data((message + "\n").utf8))
    }
}

private struct RPCResponse<Result: Decodable>: Decodable {
    let result: Result?
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: ResetCredits?
}

private struct ResetCredits: Decodable {
    let availableCount: Int
    let credits: [ResetCredit]?
}

private struct ResetCredit: Decodable {
    let expiresAt: Int64?
}

private struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

private struct UsageResult: Decodable {
    let dailyUsageBuckets: [TokenBucket]?
}

private struct TokenBucket: Decodable {
    let startDate: String
    let tokens: Int64
}
