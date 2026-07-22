import XCTest
@testable import CodexLimits

final class CodexClientTests: XCTestCase {
    func testDecodesMainLimitOtherLimitsAndUsageHistory() throws {
        let rateLimits = Data(#"""
        {"id":2,"result":{
          "rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
          "rateLimitsByLimitId":{
            "codex":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}},
            "codex_example":{"limitId":"codex_example","limitName":"Example model","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":2100000}}
          },
          "rateLimitResetCredits":{"availableCount":3,"credits":[
            {"id":"later","grantedAt":1800000,"expiresAt":2200000,"resetType":"codexRateLimits","status":"available"},
            {"id":"next","grantedAt":1800000,"expiresAt":2100000,"resetType":"codexRateLimits","status":"available"},
            {"id":"none","grantedAt":1800000,"expiresAt":null,"resetType":"codexRateLimits","status":"available"}
          ]}
        }}
        """#.utf8)
        let usage = Data(#"""
        {"id":3,"result":{
          "dailyUsageBuckets":[
            {"startDate":"2001-01-01","tokens":1000},
            {"startDate":"2001-01-02","tokens":250}
          ]
        }}
        """#.utf8)
        let fetchedAt = Date(timeIntervalSince1970: 1_900_000)

        let result = try CodexClient.decode(
            rateLimitsResponse: rateLimits,
            usageResponse: usage,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(result.mainLimit.window.remainingPercent, 80)
        XCTAssertEqual(result.planType, "prolite")
        XCTAssertEqual(result.subscriptionName, "Codex Pro 5×")
        XCTAssertEqual(result.mainLimit.window.durationMinutes, 10_080)
        XCTAssertEqual(result.mainLimit.window.resetsAt, Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(result.otherLimits.map(\.name), ["Example model"])
        XCTAssertEqual(result.tokenHistory.map(\.tokens), [1_000, 250])
        XCTAssertEqual(result.emergencyResetCount, 3)
        XCTAssertEqual(result.nextEmergencyResetExpiration, Date(timeIntervalSince1970: 2_100_000))
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    @MainActor
    func testReusesAppServerAcrossFetches() async throws {
        let fixture = try makeServerFixture()
        defer { fixture.remove() }
        let client = CodexClient(
            executablePaths: [fixture.executable.path],
            requestTimeoutNanoseconds: 2_000_000_000
        )
        defer { client.shutdown() }

        _ = try await client.fetch()
        _ = try await client.fetch()

        XCTAssertEqual(try fixture.launchCount(), 1)
    }

    @MainActor
    func testRestartsAndRetriesCurrentFetchAfterConnectionFailure() async throws {
        let fixture = try makeServerFixture(failFirstConnection: true)
        defer { fixture.remove() }
        let client = CodexClient(
            executablePaths: [fixture.executable.path],
            requestTimeoutNanoseconds: 2_000_000_000
        )
        defer { client.shutdown() }

        let result = try await client.fetch()

        XCTAssertEqual(result.mainLimit.window.remainingPercent, 80)
        XCTAssertEqual(try fixture.launchCount(), 2)
    }

    @MainActor
    func testRestartsBeforeFetchWhenCLIExecutableChanges() async throws {
        let fixture = try makeServerFixture()
        defer { fixture.remove() }
        let client = CodexClient(
            executablePaths: [fixture.executable.path],
            requestTimeoutNanoseconds: 2_000_000_000
        )
        defer { client.shutdown() }

        _ = try await client.fetch()
        try fixture.markExecutableUpdated()
        _ = try await client.fetch()

        XCTAssertEqual(try fixture.launchCount(), 2)
    }

    @MainActor
    func testRestartsBeforeFetchWhenConnectionIsFiveHoursOld() async throws {
        let fixture = try makeServerFixture()
        defer { fixture.remove() }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let client = CodexClient(
            executablePaths: [fixture.executable.path],
            requestTimeoutNanoseconds: 2_000_000_000,
            now: { now }
        )
        defer { client.shutdown() }

        _ = try await client.fetch()
        now = now.addingTimeInterval(5 * 60 * 60)
        _ = try await client.fetch()

        XCTAssertEqual(try fixture.launchCount(), 2)
    }

    @MainActor
    func testDoesNotRestartForValidServerErrorResponse() async throws {
        let fixture = try makeServerFixture(returnServerError: true)
        defer { fixture.remove() }
        let client = CodexClient(
            executablePaths: [fixture.executable.path],
            requestTimeoutNanoseconds: 2_000_000_000
        )
        defer { client.shutdown() }

        do {
            _ = try await client.fetch()
            XCTFail("Expected the server error to be reported")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(try fixture.launchCount(), 1)
    }

    private func makeServerFixture(
        failFirstConnection: Bool = false,
        returnServerError: Bool = false
    ) throws -> ServerFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-client-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex")
        let launchLog = directory.appendingPathComponent("launches")
        let failureMarker = directory.appendingPathComponent("failed-once")
        let script = #"""
        #!/bin/sh
        launch_log='\#(launchLog.path)'
        failure_marker='\#(failureMarker.path)'
        printf 'launch\n' >> "$launch_log"
        fail_this_connection=0
        if [ "\#(failFirstConnection ? "1" : "0")" = "1" ] && [ ! -f "$failure_marker" ]; then
            : > "$failure_marker"
            fail_this_connection=1
        fi
        while IFS= read -r line; do
            request_id=$(printf '%s\n' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            case "$line" in
                *'"method":"initialize"'*)
                    printf '{"id":%s,"result":{}}\n' "$request_id"
                    ;;
                *'"method":"account/rateLimits/read"'*)
                    if [ "$fail_this_connection" = "1" ]; then
                        exit 1
                    fi
                    if [ "\#(returnServerError ? "1" : "0")" = "1" ]; then
                        printf '{"id":%s,"error":{"code":123,"message":"test error"}}\n' "$request_id"
                    else
                        printf '{"id":%s,"result":{"rateLimits":{"limitId":"codex","planType":"prolite","primary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":2000000}}}}\n' "$request_id"
                    fi
                    ;;
                *'"method":"account/usage/read"'*)
                    printf '{"id":%s,"result":{"dailyUsageBuckets":[]}}\n' "$request_id"
                    ;;
            esac
        done
        """#
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return ServerFixture(
            directory: directory,
            executable: executable,
            launchLog: launchLog
        )
    }
}

private struct ServerFixture {
    let directory: URL
    let executable: URL
    let launchLog: URL

    func launchCount() throws -> Int {
        try String(contentsOf: launchLog, encoding: .utf8)
            .split(separator: "\n")
            .count
    }

    func markExecutableUpdated() throws {
        var contents = try Data(contentsOf: executable)
        contents.append(Data("\n# updated\n".utf8))
        try contents.write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o755,
                .modificationDate: Date().addingTimeInterval(2)
            ],
            ofItemAtPath: executable.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
