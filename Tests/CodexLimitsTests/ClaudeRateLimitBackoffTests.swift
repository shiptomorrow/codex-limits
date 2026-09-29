import XCTest
@testable import CodexLimits

final class ClaudeRateLimitBackoffTests: XCTestCase {
    func testBackoffStepsUpThenRepeatsFiveMinutes() {
        let delays = (0 ..< 5).map {
            ClaudeClient.rateLimitBackoff(afterConsecutiveRateLimits: $0, serverRetryAfter: 0)
        }

        XCTAssertEqual(delays, [60, 180, 300, 300, 300])
    }

    func testLongerServerRetryAfterWins() {
        XCTAssertEqual(
            ClaudeClient.rateLimitBackoff(afterConsecutiveRateLimits: 0, serverRetryAfter: 120),
            120
        )
        XCTAssertEqual(
            ClaudeClient.rateLimitBackoff(afterConsecutiveRateLimits: 2, serverRetryAfter: 120),
            300
        )
    }
}
