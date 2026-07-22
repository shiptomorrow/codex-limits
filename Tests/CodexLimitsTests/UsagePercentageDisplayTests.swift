import XCTest
@testable import CodexLimits

final class UsagePercentageDisplayTests: XCTestCase {
    func testDisplaysRemainingPercentageByDefault() {
        XCTAssertEqual(
            UsagePercentageDisplay.value(remainingPercent: 73, showsUsed: false),
            73
        )
    }

    func testCanDisplayUsedPercentage() {
        XCTAssertEqual(
            UsagePercentageDisplay.value(remainingPercent: 73, showsUsed: true),
            27
        )
    }

    func testClampsPercentageBeforeConverting() {
        XCTAssertEqual(
            UsagePercentageDisplay.value(remainingPercent: 105, showsUsed: true),
            0
        )
        XCTAssertEqual(
            UsagePercentageDisplay.value(remainingPercent: -5, showsUsed: false),
            0
        )
    }
}
