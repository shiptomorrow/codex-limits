import XCTest
@testable import CodexLimits

final class OtherLimitPreferencesTests: XCTestCase {
    func testHidesCodex53SparkByName() {
        let limits = [
            limit(id: "codex_spark", name: "GPT-5.3-Codex-Spark"),
            limit(id: "codex_example", name: "Example model")
        ]

        let visible = OtherLimitPreferences.visibleLimits(
            from: limits,
            hideCodex53Spark: true
        )

        XCTAssertEqual(visible.map(\.name), ["Example model"])
    }

    func testShowsCodex53SparkWhenPreferenceIsOff() {
        let limits = [limit(id: "gpt_5_3_codex_spark", name: "5.3 Spark")]

        let visible = OtherLimitPreferences.visibleLimits(
            from: limits,
            hideCodex53Spark: false
        )

        XCTAssertEqual(visible, limits)
    }

    func testDoesNotHideOtherSparkVersions() {
        let limits = [limit(id: "gpt_5_4_codex_spark", name: "GPT-5.4-Codex-Spark")]

        let visible = OtherLimitPreferences.visibleLimits(
            from: limits,
            hideCodex53Spark: true
        )

        XCTAssertEqual(visible, limits)
    }

    private func limit(id: String, name: String) -> LimitReading {
        LimitReading(
            limitId: id,
            name: name,
            window: UsageWindow(
                remainingPercent: 50,
                resetsAt: Date(timeIntervalSince1970: 2_000_000),
                durationMinutes: 10_080
            )
        )
    }
}
