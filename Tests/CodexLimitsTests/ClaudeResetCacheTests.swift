import XCTest
@testable import CodexLimits

final class ClaudeResetCacheTests: XCTestCase {
    func testEntryFileNameMatchesChromiumSimpleCache() {
        let key = "1/0/https://claude.ai/api/organizations/198f7d50-e9b0-43b3-8a5f-00f845176789"
            + "/usage?cedar_ember=1&skip_spend=1"

        XCTAssertEqual(ClaudeResetCache.entryFileName(forKey: key), "0ef35bdd3509dd23_0")
    }

    func testCountsUnexpiredGrantsWithResetsLeft() throws {
        let usage = Data("""
        {
          "cedar_ember": {
            "grants": [
              { "resets_left": 1, "ends_at": "2026-10-22T16:00:00+00:00" },
              { "resets_left": 2, "ends_at": "2026-11-01T16:00:00+00:00" },
              { "resets_left": 0, "ends_at": "2026-10-20T16:00:00+00:00" },
              { "resets_left": 1, "ends_at": "2026-10-01T16:00:00+00:00" }
            ]
          }
        }
        """.utf8)
        let now = try XCTUnwrap(ClaudeClient.date("2026-10-14T19:00:00+00:00"))

        let grants = ClaudeResetCache.grants(fromUsage: usage, now: now)

        XCTAssertEqual(grants, ClaudeResetGrants(
            resetsLeft: 3,
            nextExpiration: ClaudeClient.date("2026-10-22T16:00:00+00:00")
        ))
    }
}
