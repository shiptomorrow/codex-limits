import XCTest
@testable import CodexLimits

final class ClaudeRateLimitBackoffTests: XCTestCase {
    func testBackoffStepsUpThenRepeatsFiveMinutes() {
        let delays = (0 ..< 6).map {
            ClaudeClient.rateLimitBackoff(afterConsecutiveRateLimits: $0, serverRetryAfter: 0)
        }

        XCTAssertEqual(delays, [10, 60, 180, 300, 300, 300])
    }

    func testLongerServerRetryAfterWins() {
        XCTAssertEqual(
            ClaudeClient.rateLimitBackoff(afterConsecutiveRateLimits: 0, serverRetryAfter: 120),
            120
        )
        XCTAssertEqual(
            ClaudeClient.rateLimitBackoff(afterConsecutiveRateLimits: 3, serverRetryAfter: 120),
            300
        )
    }
}
