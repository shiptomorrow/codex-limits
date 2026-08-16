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

final class BurnDownHoverSegmentTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 2_000)

    func testActualUsageSnapsToLastSample() {
        let hoveredDate = Date(timeIntervalSince1970: 1_750)
        let value = makeSegment(isStep: true)
            .hoverValue(at: hoveredDate)

        XCTAssertEqual(value.date, hoveredDate)
        XCTAssertEqual(value.labelDate, start)
        XCTAssertEqual(value.percent, 20)
    }

    func testActualUsageUsesNewSampleAtEndpoint() {
        let value = makeSegment(isStep: true).hoverValue(at: end)

        XCTAssertEqual(value.date, end)
        XCTAssertEqual(value.labelDate, end)
        XCTAssertEqual(value.percent, 40)
    }

    func testProjectionKeepsEstimatedPointerTime() {
        let hoveredDate = Date(timeIntervalSince1970: 1_750)
        let value = makeSegment(isStep: false).hoverValue(at: hoveredDate)

        XCTAssertEqual(value.date, hoveredDate)
        XCTAssertEqual(value.labelDate, hoveredDate)
        XCTAssertEqual(value.percent, 35, accuracy: 0.001)
    }

    private func makeSegment(isStep: Bool) -> BurnDownHoverSegment {
        BurnDownHoverSegment(
            startDate: start,
            endDate: end,
            startPercent: 20,
            endPercent: 40,
            color: .blue,
            lastValueChangeDate: start,
            isStep: isStep
        )
    }
}
