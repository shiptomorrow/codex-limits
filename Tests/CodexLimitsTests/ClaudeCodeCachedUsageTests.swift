import XCTest
@testable import CodexLimits

final class ClaudeCodeCachedUsageTests: XCTestCase {
    private func config(cacheAccount: String, signedInAccount: String) -> Data {
        Data("""
        {
          "oauthAccount": { "accountUuid": "\(signedInAccount)" },
          "cachedUsageUtilization": {
            "fetchedAtMs": 1792005751302,
            "accountUuid": "\(cacheAccount)",
            "utilization": {
              "five_hour": { "utilization": 58, "resets_at": "2026-10-14T20:10:00.137069+00:00" },
              "seven_day": { "utilization": 10, "resets_at": "2026-10-21T04:00:00.137094+00:00" }
            }
          }
        }
        """.utf8)
    }

    func testReadsCacheForSignedInAccount() throws {
        let cached = try XCTUnwrap(ClaudeClient.cachedUsage(
            fromClaudeCodeConfig: config(cacheAccount: "a", signedInAccount: "a"),
            planType: "claude_max_20x"
        ))

        XCTAssertEqual(cached.fetchedAt, Date(timeIntervalSince1970: 1_792_005_751.302))
        XCTAssertEqual(cached.snapshot.mainLimit.window.remainingPercent, 42)
        XCTAssertEqual(cached.snapshot.planType, "claude_max_20x")
    }

    func testIgnoresCacheFromAnotherAccount() {
        XCTAssertNil(ClaudeClient.cachedUsage(
            fromClaudeCodeConfig: config(cacheAccount: "a", signedInAccount: "b"),
            planType: nil
        ))
    }
}
