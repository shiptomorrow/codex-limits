import XCTest
@testable import CodexLimits

final class ServerUsageLogTests: XCTestCase {
    func testDecodesWindowsIntoFiveHourAndWeeklySamples() throws {
        let data = Data(#"""
        {"version":1,"installed":true,
         "state":{"lastRunAt":1000,"lastError":null,"lastSuccessAt":1000},
         "entries":[
           {"t":900,"account":"same","windows":[
             {"minutes":300,"remaining":70.0,"resetsAt":5000},
             {"minutes":10080,"remaining":90.0,"resetsAt":600000},
             {"minutes":43200,"remaining":99.0,"resetsAt":900000}]},
           {"t":950,"account":"other","windows":[{"minutes":300,"remaining":10.0,"resetsAt":5000}]}
         ]}
        """#.utf8)

        let export = try ServerUsageLog.decodeExport(data, provider: .codex, localAccount: "same")

        XCTAssertTrue(export.installed)
        XCTAssertEqual(export.lastRunAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(export.lastError)
        XCTAssertEqual(export.fiveHourSamples, [UsageSample(
            observedAt: Date(timeIntervalSince1970: 900),
            remainingPercent: 70,
            resetsAt: Date(timeIntervalSince1970: 5_000)
        )])
        XCTAssertEqual(export.weeklySamples.map(\.remainingPercent), [90])
        XCTAssertEqual(export.otherAccountEntryCount, 1)
        XCTAssertEqual(export.newestEntryTime, 950)
        XCTAssertNil(export.macLoggingUntil)
    }

    func testDecodesMacLoggingLease() throws {
        let data = Data(#"{"version":1,"installed":true,"macLoggingUntil":2000,"state":{},"entries":[]}"#.utf8)

        let export = try ServerUsageLog.decodeExport(data, provider: .claude, localAccount: nil)

        XCTAssertEqual(export.macLoggingUntil, Date(timeIntervalSince1970: 2_000))
    }

    func testKeepsEntriesWhenLocalAccountIsUnknown() throws {
        let data = Data(#"""
        {"version":1,"installed":true,"state":{},
         "entries":[{"t":900,"account":"remote","windows":[{"minutes":300,"remaining":70,"resetsAt":5000}]}]}
        """#.utf8)

        let export = try ServerUsageLog.decodeExport(data, provider: .claude, localAccount: nil)

        XCTAssertEqual(export.fiveHourSamples.count, 1)
        XCTAssertEqual(export.otherAccountEntryCount, 0)
    }

    func testPhrasesLoggerErrors() throws {
        let data = Data(#"{"version":1,"installed":true,"state":{"lastRunAt":1,"lastError":"credentialsNotFound"},"entries":[]}"#.utf8)

        let export = try ServerUsageLog.decodeExport(data, provider: .claude, localAccount: nil)

        XCTAssertEqual(export.lastError, "Claude Code isn’t signed in on this host.")
        XCTAssertEqual(
            ServerUsageLog.message(forLoggerError: "rpc:401 Unauthorized", provider: .codex),
            CodexClientError.authenticationFailed.errorDescription
        )
    }

    func testThrowsHelperErrors() {
        XCTAssertThrowsError(try ServerUsageLog.decodeExport(
            Data(#"{"version":1,"error":"cronMissing"}"#.utf8),
            provider: .codex,
            localAccount: nil
        )) { error in
            XCTAssertEqual(
                error as? ServerUsageLogError,
                .logger("cron isn’t available on this host, so usage can’t be logged there.")
            )
        }
    }

    func testAccountHashMatchesServerLogger() {
        // sha256("codex:account-123"), as computed by Resources/remote-usage.py.
        XCTAssertEqual(
            UsageAccountIdentity.hash(provider: .codex, accountID: "account-123"),
            "4ea4535004333c45028f3a92c3bf81be56029d79b480923a09a8a4811add3f73"
        )
    }

    func testHistoryWriterIsSafeDirectoryName() {
        XCTAssertEqual(ServerUsageLog.historyWriter(for: "res"), "server-res")
        XCTAssertEqual(ServerUsageLog.historyWriter(for: "a/b c"), "server-a_b_c")
    }
}
