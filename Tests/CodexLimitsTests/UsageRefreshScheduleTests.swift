import XCTest
@testable import CodexLimits

final class UsageRefreshScheduleTests: XCTestCase {
    func testDefaultAndFastChoices() {
        XCTAssertEqual(UsageRefreshSchedule.defaultSeconds, 15)
        XCTAssertEqual(Array(UsageRefreshSchedule.choices.prefix(6)), [1, 2, 5, 10, 15, 30])
    }

    func testClampsToSupportedRange() {
        XCTAssertEqual(UsageRefreshSchedule.clamped(0), 1)
        XCTAssertEqual(UsageRefreshSchedule.clamped(15), 15)
        XCTAssertEqual(UsageRefreshSchedule.clamped(7_200), 3_600)
    }
}
