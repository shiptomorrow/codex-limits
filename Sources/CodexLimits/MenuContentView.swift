import AppKit
import Charts
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: UsageMonitor
    var openSettingsAction: (() -> Void)?
    @AppStorage(UsageMonitor.safetyBufferKey) private var safetyBuffer = 3.0
    @AppStorage(UsageMonitor.showPreviousWeeklyWindowKey) private var showPreviousWeeklyWindow = false
    @Environment(\.openSettings) private var openSettings
    @State private var chartMode: ChartMode = .usage

    var body: some View {
        Group {
            if let snapshot = monitor.snapshot, let forecast = monitor.forecast {
                dashboard(snapshot: snapshot, forecast: forecast)
            } else {
                emptyState
            }
        }
        .frame(width: 420)
        .padding(16)
        .task { await monitor.refresh() }
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private func dashboard(snapshot: UsageSnapshot, forecast: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(snapshot.mainLimit.window.remainingPercent, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("% remaining")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(weeklyPaceValueText)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("/ week pace")
                        .foregroundStyle(.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(usingPaceValueText(forecast: forecast))
                            .font(.system(size: 20))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(" used / day")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                        .offset(y: 44)
                }
                .help("Estimated active Codex hours supported by a full weekly allowance at the recent pace")
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    if monitor.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
                .accessibilityLabel("Refresh usage")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle(forecast.status))
                    .font(.headline)
                    .foregroundStyle(statusColor(forecast.status))
                Text(statusMessage(snapshot: snapshot, forecast: forecast))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button {
                        chartMode = chartMode == .usage ? .weeklyPace : .usage
                    } label: {
                        Label(
                            chartMode == .usage ? "Hours / week" : "Usage",
                            systemImage: chartMode == .usage ? "clock.arrow.trianglehead.counterclockwise.rotate.90" : "percent"
                        )
                    }
                    .controlSize(.small)
                    .help(chartMode == .usage ? "Show estimated hours per week pace" : "Show usage forecast")
                    .accessibilityLabel(chartMode == .usage ? "Show hours per week pace graph" : "Show usage forecast graph")
                }

                if chartMode == .usage {
                    BurnDownChart(
                        window: snapshot.mainLimit.window,
                        samples: monitor.currentWindowSamples,
                        tokenHistory: snapshot.tokenHistory,
                        fetchedAt: snapshot.fetchedAt,
                        forecast: forecast,
                        safetyBuffer: safetyBuffer
                    )
                } else if let weeklyWindow = weeklyWindow(in: snapshot) {
                    WeeklyPaceChart(
                        window: weeklyWindow,
                        points: monitor.weeklyPacePoints,
                        fetchedAt: snapshot.fetchedAt,
                        showsPreviousWindow: showPreviousWeeklyWindow
                    )
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("Reset in")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(countdownText(until: snapshot.mainLimit.window.resetsAt, now: context.date))
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text("Suggested pace")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(paceText(forecast: forecast))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("Banked resets")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(snapshot.emergencyResetCount, format: .number)
                                .monospacedDigit()
                        }
                        HStack(spacing: 6) {
                            Text("Oldest reset expires in")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let expiration = snapshot.nextEmergencyResetExpiration {
                                Text(countdownText(until: expiration, now: context.date))
                                    .lineLimit(1)
                            } else {
                                Text("—")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            if !snapshot.otherLimits.isEmpty {
                Divider()
                Text("Other limits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(snapshot.otherLimits) { limit in
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        HStack {
                            Text(limit.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(limit.window.remainingPercent.rounded()))%")
                                .monospacedDigit()
                            Text(countdownText(until: limit.window.resetsAt, now: context.date))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            if let error = monitor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(updatedText(snapshot.fetchedAt, now: context.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let openSettingsAction {
                        openSettingsAction()
                    } else {
                        openSettings()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.windows.first {
                            $0.isVisible && $0.styleMask.contains(.titled)
                        }?.orderFrontRegardless()
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var weeklyPaceValueText: String {
        guard let hours = monitor.weeklyPaceHours else {
            return "—h"
        }
        let digits = hours < 10 ? 1 : 0
        let value = hours.formatted(.number.precision(.fractionLength(digits)))
        return "\(value)h"
    }

    private func usingPaceValueText(forecast: Forecast) -> String {
        guard let weeklyPaceHours = monitor.weeklyPaceHours else {
            return "—h"
        }
        let hoursPerDay = weeklyPaceHours * forecast.currentPercentPerDay / 100
        return "\(oneDecimal(hoursPerDay))h"
    }

    private func weeklyWindow(in snapshot: UsageSnapshot) -> UsageWindow? {
        ([snapshot.mainLimit] + snapshot.otherLimits)
            .first { $0.limitId == "codex" && $0.window.durationMinutes == 10_080 }?
            .window
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if monitor.isRefreshing {
                ProgressView()
                Text("Reading Codex usage…")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                Text(monitor.errorMessage ?? "Codex usage is not available.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    Task { await monitor.refresh() }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func statusTitle(_ status: PaceStatus) -> String {
        switch status {
        case .slowDown: "Slow down"
        case .onTrack: "On track"
        case .roomToUseMore: "Room to use more"
        }
    }

    private func statusColor(_ status: PaceStatus) -> Color {
        switch status {
        case .slowDown: .red
        case .onTrack: .green
        case .roomToUseMore: .blue
        }
    }

    private func statusMessage(snapshot: UsageSnapshot, forecast: Forecast) -> String {
        switch forecast.status {
        case .slowDown:
            let window = snapshot.mainLimit.window
            let timeLeft = window.resetsAt.timeIntervalSince(snapshot.fetchedAt)
            let timeToEmpty = window.remainingPercent / max(forecast.safetyPercentPerDay, 0.01) * 86_400
            let early = max(timeLeft - timeToEmpty, 0)
            return early > 0
                ? "At this pace, your limit may run out \(durationText(early)) early."
                : "Your current pace is too close to the limit."
        case .onTrack:
            return "You’re on track to have \(Int(forecast.expectedRemainingAtReset.rounded()))% left at reset."
        case .roomToUseMore:
            let room = max(forecast.expectedRemainingAtReset - safetyBuffer, 0)
            return "You can use about \(Int(room.rounded()))% more before the reset."
        }
    }

    private func paceText(forecast: Forecast) -> String {
        guard let weeklyPaceHours = monitor.weeklyPaceHours else {
            return "— hr / day"
        }
        let recommendedHoursPerDay = weeklyPaceHours * forecast.recommendedPercentPerDay / 100
        if recommendedHoursPerDay < 1 {
            let recommendedMinutesPerDay = Int((recommendedHoursPerDay * 60).rounded())
            return "\(recommendedMinutesPerDay) min / day"
        }
        return "\(oneDecimal(recommendedHoursPerDay)) hr / day"
    }

    private func countdownText(until date: Date, now: Date) -> String {
        let totalMinutes = Int(date.timeIntervalSince(now) / 60)
        guard totalMinutes > 0 else { return "Now" }

        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes / 60 % 24
        if days > 0 { return "\(days)d \(hours)h" }

        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(1))
                .locale(Locale(identifier: "en_US"))
        )
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400 {
            let days = max(Int((seconds / 86_400).rounded()), 1)
            return "\(days) \(days == 1 ? "day" : "days")"
        }
        let hours = max(Int((seconds / 3_600).rounded()), 1)
        return "\(hours) \(hours == 1 ? "hour" : "hours")"
    }

    private func updatedText(_ date: Date, now: Date) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(Int(seconds / 60)) min ago" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            return "Updated \(hours) \(hours == 1 ? "hr" : "hrs") ago"
        }
        let days = Int(seconds / 86_400)
        return "Updated \(days) \(days == 1 ? "day" : "days") ago"
    }
}

private enum ChartMode {
    case usage
    case weeklyPace
}

private struct WeeklyPaceChart: View {
    let window: UsageWindow
    let points: [WeeklyPacePoint]
    let fetchedAt: Date
    let showsPreviousWindow: Bool

    private var displayedPoints: [WeeklyPacePoint] {
        points
            .filter {
                showsPreviousWindow
                    || abs($0.windowResetsAt.timeIntervalSince(window.resetsAt)) <= 5 * 60
            }
            .sorted { $0.date < $1.date }
    }

    private var hasPreviousPoints: Bool {
        displayedPoints.contains {
            abs($0.windowResetsAt.timeIntervalSince(window.resetsAt)) > 5 * 60
        }
    }

    private var resetTransition: WeeklyPaceResetTransition? {
        guard
            let lastPrevious = displayedPoints.last(where: {
                abs($0.windowResetsAt.timeIntervalSince(window.resetsAt)) > 5 * 60
            }),
            let firstCurrent = displayedPoints.first(where: {
                abs($0.windowResetsAt.timeIntervalSince(window.resetsAt)) <= 5 * 60
            })
        else { return nil }

        return WeeklyPaceResetTransition(
            previousDate: lastPrevious.date,
            currentDate: firstCurrent.date
        )
    }

    private var timeline: WeeklyPaceCompressedTimeline {
        WeeklyPaceCompressedTimeline(
            dates: displayedPoints.map(\.date) + [fetchedAt],
            resetTransition: resetTransition
        )
    }

    private var resetPosition: Double? {
        guard let resetTransition else { return nil }
        let previous = timeline.position(for: resetTransition.previousDate)
        let current = timeline.position(for: resetTransition.currentDate)
        return (previous + current) / 2
    }

    private var maximumHours: Double {
        let maximum = displayedPoints.map(\.hoursPerWeek).max() ?? 0
        return max(ceil(maximum / 5) * 5, 10)
    }

    private var xDomain: ClosedRange<Double> {
        let nowPosition = timeline.position(for: fetchedAt)
        let end = max(nowPosition / 0.75, 60 * 60)
        return 0 ... end
    }

    private var xAxisValues: [Double] {
        let duration = xDomain.upperBound - xDomain.lowerBound
        return (0 ... 4).map {
            xDomain.lowerBound + Double($0) * duration / 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ChartLegendItem(label: "Estimated pace", color: .purple)
                Spacer()
                Text("hours / week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if displayedPoints.isEmpty {
                ContentUnavailableView(
                    "Not enough pace data",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Use Codex while this app records weekly usage history.")
                )
                .frame(height: 190)
            } else {
                Chart {
                    ForEach(displayedPoints) { point in
                        LineMark(
                            x: .value("Compressed time", timeline.position(for: point.date)),
                            y: .value("Hours per week", point.hoursPerWeek)
                        )
                        .foregroundStyle(Color.purple)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.stepEnd)
                    }

                    RuleMark(x: .value("Now", timeline.position(for: fetchedAt)))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                    if showsPreviousWindow, let resetPosition {
                        RuleMark(x: .value("Weekly reset", resetPosition))
                            .foregroundStyle(Color.secondary.opacity(0.75))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .annotation(position: .top, spacing: 4) {
                                Text("Reset")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }

                    if let latest = displayedPoints.last {
                        PointMark(
                            x: .value("Latest", timeline.position(for: latest.date)),
                            y: .value("Latest pace", latest.hoursPerWeek)
                        )
                        .foregroundStyle(Color.purple)
                        .symbolSize(28)
                        .annotation(position: .top, spacing: 5) {
                            Text("\(latest.hoursPerWeek.formatted(.number.precision(.fractionLength(latest.hoursPerWeek < 10 ? 1 : 0)))) h")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(.regularMaterial).opacity(0.7) }
                        }
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: [maximumHours, 0])
                .chartXAxis {
                    AxisMarks(values: xAxisValues) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisTick(length: 3).foregroundStyle(Color.secondary)
                        AxisValueLabel {
                            if let position = value.as(Double.self) {
                                let date = timeline.date(at: position)
                                if timeline.realDuration <= 24 * 60 * 60 {
                                    Text(date, format: .dateTime.hour().minute())
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .offset(x: position == xDomain.lowerBound ? 8 : position == xDomain.upperBound ? -8 : 0)
                                } else {
                                    Text(date, format: .dateTime.weekday(.abbreviated))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .offset(x: position == xDomain.lowerBound ? 8 : position == xDomain.upperBound ? -8 : 0)
                                }
                            }
                        }
                        .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            .foregroundStyle(Color.secondary.opacity(0.2))
                        AxisTick(length: 3).foregroundStyle(Color.secondary)
                        AxisValueLabel {
                            if let hours = value.as(Double.self) {
                                Text("\(Int(hours.rounded()))h")
                            }
                        }
                        .foregroundStyle(Color.secondary)
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 190)
                .padding(.horizontal, 8)
                .accessibilityLabel("Estimated hours per week pace")
                .accessibilityValue(latestAccessibilityValue)
            }
        }
    }

    private var latestAccessibilityValue: String {
        guard let latest = displayedPoints.last else { return "Not enough data" }
        return "Latest estimate is \(latest.hoursPerWeek.formatted(.number.precision(.fractionLength(1)))) hours per week."
    }
}

struct WeeklyPaceCompressedTimeline {
    private struct Anchor {
        let date: Date
        let position: Double
    }

    private static let maximumGap: TimeInterval = 60 * 60
    private let anchors: [Anchor]

    init(dates: [Date], resetTransition: WeeklyPaceResetTransition? = nil) {
        let dates = Array(Set(dates)).sorted()
        guard let first = dates.first else {
            anchors = []
            return
        }

        var result = [Anchor(date: first, position: 0)]
        for date in dates.dropFirst() {
            let previous = result[result.count - 1]
            let isResetTransition = resetTransition.map {
                previous.date == $0.previousDate && date == $0.currentDate
            } ?? false
            let maximumGap = isResetTransition ? 5 * 60 : Self.maximumGap
            let gap = min(max(date.timeIntervalSince(previous.date), 0), maximumGap)
            result.append(Anchor(date: date, position: previous.position + gap))
        }
        anchors = result
    }

    var realDuration: TimeInterval {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        return last.date.timeIntervalSince(first.date)
    }

    func position(for date: Date) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if date <= first.date {
            return first.position - min(first.date.timeIntervalSince(date), Self.maximumGap)
        }

        for index in 1 ..< anchors.count {
            let lower = anchors[index - 1]
            let upper = anchors[index]
            guard date <= upper.date else { continue }
            let realGap = upper.date.timeIntervalSince(lower.date)
            guard realGap > 0 else { return upper.position }
            let fraction = date.timeIntervalSince(lower.date) / realGap
            return lower.position + fraction * (upper.position - lower.position)
        }

        return last.position + min(date.timeIntervalSince(last.date), Self.maximumGap)
    }

    func date(at position: Double) -> Date {
        guard let first = anchors.first, let last = anchors.last else { return Date() }
        if position <= first.position {
            return first.date.addingTimeInterval(position - first.position)
        }

        for index in 1 ..< anchors.count {
            let lower = anchors[index - 1]
            let upper = anchors[index]
            guard position <= upper.position else { continue }
            let displayedGap = upper.position - lower.position
            guard displayedGap > 0 else { return upper.date }
            let fraction = (position - lower.position) / displayedGap
            return lower.date.addingTimeInterval(
                fraction * upper.date.timeIntervalSince(lower.date)
            )
        }

        return last.date.addingTimeInterval(position - last.position)
    }
}

struct WeeklyPaceResetTransition {
    let previousDate: Date
    let currentDate: Date
}

private struct BurnDownChart: View {
    let window: UsageWindow
    let samples: [UsageSample]
    let tokenHistory: [TokenDay]
    let fetchedAt: Date
    let forecast: Forecast
    let safetyBuffer: Double

    private var observed: [BurnPoint] {
        let current = BurnPoint(date: fetchedAt, remaining: window.remainingPercent)
        let local = samples
            .filter { $0.observedAt > window.startsAt && $0.observedAt < fetchedAt }
            .map { BurnPoint(date: $0.observedAt, remaining: $0.remainingPercent) }
            .sorted { $0.date < $1.date }
        let firstKnown = local.first ?? current
        let buckets = tokenHistory
            .filter {
                $0.date.addingTimeInterval(86_400) > window.startsAt && $0.date < firstKnown.date
            }
            .sorted { $0.date < $1.date }
        let totalTokens = buckets.reduce(Int64(0)) { $0 + $1.tokens }
        var bootstrapped: [BurnPoint] = []

        if totalTokens > 0 {
            var cumulativeTokens: Int64 = 0
            for bucket in buckets {
                cumulativeTokens += bucket.tokens
                let date = min(
                    max(bucket.date.addingTimeInterval(86_400), window.startsAt),
                    firstKnown.date
                )
                let used = (100 - firstKnown.remaining) * Double(cumulativeTokens) / Double(totalTokens)
                bootstrapped.append(BurnPoint(date: date, remaining: 100 - used))
            }
        }

        // Daily token buckets seed the curve until percentage samples cover the window.
        return deduplicated(
            [BurnPoint(date: window.startsAt, remaining: 100)] + bootstrapped + local + [current]
        )
    }

    private var currentColor: Color {
        forecast.currentPercentPerDay > forecast.historicalPercentPerDay ? .red : .blue
    }

    private var currentProjection: [BurnPoint] {
        projection(rate: forecast.currentPercentPerDay, remainingAtReset: forecast.expectedRemainingAtReset)
    }

    private var historicalProjection: [BurnPoint] {
        projection(rate: forecast.historicalPercentPerDay, remainingAtReset: forecast.historicalRemainingAtReset)
    }

    private var xAxisDates: [Date] {
        let step: TimeInterval = window.durationMinutes <= 24 * 60 ? 3_600 : 86_400
        var dates: [Date] = []
        var date = window.startsAt
        while date < window.resetsAt {
            dates.append(date)
            date = date.addingTimeInterval(step)
        }
        dates.append(window.resetsAt)
        return dates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ChartLegendItem(label: "Target", color: .green, dash: [3, 3])
                ChartLegendItem(label: "Actual", color: .blue)
                ChartLegendItem(label: "Current", color: currentColor, dash: [7, 3])
                ChartLegendItem(label: "Historical", color: .secondary, dash: [2, 3])
            }

            Chart {
                ForEach([
                    BurnPoint(date: window.startsAt, remaining: 100),
                    BurnPoint(date: window.resetsAt, remaining: safetyBuffer)
                ]) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Target", point.remaining),
                        series: .value("Series", "Target")
                    )
                    .foregroundStyle(Color.green.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }

                ForEach(observed) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Actual", point.remaining),
                        series: .value("Series", "Actual")
                    )
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd)
                }

                ForEach(currentProjection) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Current", point.remaining),
                        series: .value("Series", "Current")
                    )
                    .foregroundStyle(currentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [7, 3]))
                }

                ForEach(historicalProjection) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Historical", point.remaining),
                        series: .value("Series", "Historical")
                    )
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }

                RuleMark(x: .value("Now", fetchedAt))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

                PointMark(
                    x: .value("Now", fetchedAt),
                    y: .value("Remaining now", window.remainingPercent)
                )
                .foregroundStyle(currentColor)
                .symbolSize(18)
                .annotation(position: .top, spacing: 5) {
                    Text("Now")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(.regularMaterial)
                                .opacity(0.7)
                        }
                }

                PointMark(
                    x: .value("Reset", window.resetsAt),
                    y: .value("Target", safetyBuffer)
                )
                .foregroundStyle(Color.green)
                .symbolSize(38)

                if let endpoint = currentProjection.last {
                    PointMark(
                        x: .value("Current endpoint", endpoint.date),
                        y: .value("Current endpoint", endpoint.remaining)
                    )
                    .foregroundStyle(currentColor)
                    .symbolSize(12)
                }
            }
            .chartXScale(domain: window.startsAt ... window.resetsAt)
            .chartYScale(domain: 0 ... 100)
            .chartXAxis {
                AxisMarks(values: xAxisDates) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    AxisTick(length: 3)
                        .foregroundStyle(Color.secondary)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            if window.durationMinutes <= 24 * 60 {
                                Text(date, format: .dateTime.hour())
                                    .offset(x: date == window.startsAt ? 8 : date == window.resetsAt ? -8 : 0)
                            } else {
                                Text(date, format: .dateTime.weekday(.abbreviated))
                                    .offset(x: date == window.startsAt ? 8 : date == window.resetsAt ? -8 : 0)
                            }
                        }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 25.0, 50.0, 75.0, 100.0]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                    AxisTick(length: 3)
                        .foregroundStyle(Color.secondary)
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text("\(Int(percent))%")
                        }
                    }
                    .foregroundStyle(Color.secondary)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 190)
            .padding(.horizontal, 8)
            .accessibilityLabel("Usage forecast")
            .accessibilityValue(
                "Now has \(Int(window.remainingPercent.rounded())) percent remaining. At reset, the current pace leaves \(Int(forecast.expectedRemainingAtReset.rounded())) percent and the historical pace leaves \(Int(forecast.historicalRemainingAtReset.rounded())) percent."
            )
        }
    }

    private func projection(rate: Double, remainingAtReset: Double) -> [BurnPoint] {
        let current = BurnPoint(date: fetchedAt, remaining: window.remainingPercent)
        guard rate > 0 else {
            return [current, BurnPoint(date: window.resetsAt, remaining: window.remainingPercent)]
        }
        let exhaustion = fetchedAt.addingTimeInterval(window.remainingPercent / rate * 86_400)
        let endpoint = exhaustion < window.resetsAt
            ? BurnPoint(date: exhaustion, remaining: 0)
            : BurnPoint(date: window.resetsAt, remaining: remainingAtReset)
        return [current, endpoint]
    }

    private func deduplicated(_ points: [BurnPoint]) -> [BurnPoint] {
        points.sorted { $0.date < $1.date }.reduce(into: []) { result, point in
            if result.last?.date == point.date {
                result[result.count - 1] = point
            } else {
                result.append(point)
            }
        }
    }
}

private struct BurnPoint: Identifiable {
    let date: Date
    let remaining: Double

    var id: Date { date }
}

private struct ChartLegendItem: View {
    let label: String
    let color: Color
    var dash: [CGFloat] = []

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
            }
            .frame(width: 18, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @AppStorage(UsageMonitor.safetyBufferKey) private var safetyBuffer = 3.0
    @AppStorage(UsageMonitor.refreshIntervalSecondsKey) private var refreshIntervalSeconds = 60
    @AppStorage(UsageMonitor.factorInPausesKey) private var factorInPauses = true
    @AppStorage(UsageMonitor.paceLookbackMinutesKey) private var paceLookbackMinutes = 60
    @AppStorage(UsageMonitor.showPreviousWeeklyWindowKey) private var showPreviousWeeklyWindow = false
    @AppStorage(StatusItemPreferences.spacingKey) private var menuBarSpacing = 2.0
    @AppStorage(StatusItemPreferences.showsIconKey) private var showsMenuBarIcon = true
    @AppStorage(LoginItem.preferenceKey) private var launchAtLogin = true
    @State private var loginItemError: String?
    @State private var isResetHistoryConfirmationPresented = false

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: updateLaunchAtLogin
            ))

            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Stepper(value: $menuBarSpacing, in: 0 ... 12, step: 1) {
                    Text("Icon spacing: \(Int(menuBarSpacing)) pt")
                }

                Toggle("Show icon", isOn: $showsMenuBarIcon)
            }

            Section("Misc") {
                Stepper {
                    Text("Check usage every \(refreshIntervalLabel)")
                } onIncrement: {
                    setRefreshInterval(nextRefreshInterval)
                } onDecrement: {
                    setRefreshInterval(previousRefreshInterval)
                }

                Stepper(value: $safetyBuffer, in: 1 ... 10, step: 1) {
                    Text("Suggested pace buffer: \(Int(safetyBuffer))%")
                }
                .onChange(of: safetyBuffer) { _, value in
                    monitor.updateSafetyBuffer(value)
                }

                Toggle("Factor in pauses", isOn: $factorInPauses)
                    .onChange(of: factorInPauses) { _, value in
                        monitor.updateFactorInPauses(value)
                    }
                    .help("Include pauses of up to 15 minutes in the weekly pace calculation")

                Toggle("Show previous weekly window", isOn: $showPreviousWeeklyWindow)
                    .onChange(of: showPreviousWeeklyWindow) { _, value in
                        monitor.updateShowPreviousWeeklyWindow(value)
                    }
                    .help("Include the previous usage window in the hours-per-week chart")

                Stepper {
                    Text("Pace lookback: \(paceLookbackLabel)")
                } onIncrement: {
                    setPaceLookback(nextPaceLookback)
                } onDecrement: {
                    setPaceLookback(previousPaceLookback)
                }
                .help("Use this much recent activity to estimate the weekly pace")
            }

            Section("History sync") {
                Text("Keep usage history in a folder available on your other Macs.")
                    .foregroundStyle(.secondary)

                if let folderName = monitor.syncFolderName {
                    LabeledContent("Folder", value: folderName)
                    Button("Stop Syncing") {
                        Task { await monitor.stopHistorySync() }
                    }
                } else {
                    Button("Choose Folder…", action: chooseHistoryFolder)
                }

                if let syncErrorMessage = monitor.syncErrorMessage {
                    Label(syncErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Delete History", role: .destructive) {
                    isResetHistoryConfirmationPresented = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380, height: 600)
        .alert(
            "Delete usage history?",
            isPresented: $isResetHistoryConfirmationPresented
        ) {
            Button("Delete History", role: .destructive) {
                Task { await monitor.resetHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetHistoryMessage)
        }
    }

    private var refreshIntervals: [Int] {
        [15, 30] + Array(stride(from: 60, through: 3_600, by: 60))
    }

    private var paceLookbacks: [Int] {
        [15, 30, 60, 120, 180]
    }

    private var resetHistoryMessage: String {
        let location = monitor.syncFolderName == nil
            ? "on this Mac"
            : "on this Mac and in the connected sync folder"
        return "This permanently deletes saved usage samples \(location). New history will begin with the next usage check."
    }

    private var nextRefreshInterval: Int {
        refreshIntervals.first(where: { $0 > refreshIntervalSeconds }) ?? 3_600
    }

    private var previousRefreshInterval: Int {
        refreshIntervals.last(where: { $0 < refreshIntervalSeconds }) ?? 15
    }

    private var refreshIntervalLabel: String {
        if refreshIntervalSeconds < 60 {
            return "\(refreshIntervalSeconds) sec"
        }
        return "\(refreshIntervalSeconds / 60) min"
    }

    private var nextPaceLookback: Int {
        paceLookbacks.first(where: { $0 > paceLookbackMinutes }) ?? 180
    }

    private var previousPaceLookback: Int {
        paceLookbacks.last(where: { $0 < paceLookbackMinutes }) ?? 15
    }

    private var paceLookbackLabel: String {
        paceLookbackMinutes < 60
            ? "\(paceLookbackMinutes) min"
            : "\(paceLookbackMinutes / 60) hr"
    }

    private func setPaceLookback(_ minutes: Int) {
        paceLookbackMinutes = minutes
        monitor.updatePaceLookback(minutes: minutes)
    }

    private func setRefreshInterval(_ seconds: Int) {
        refreshIntervalSeconds = seconds
        monitor.updateRefreshInterval(seconds: seconds)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            loginItemError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError = "Couldn’t update the login setting."
        }
    }

    private func chooseHistoryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await monitor.connectHistoryFolder(directory) }
    }
}

enum LoginItem {
    static let preferenceKey = "launchAtLogin"

    static func enableByDefault() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: preferenceKey) == nil else { return }
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            defaults.set(true, forKey: preferenceKey)
        } catch {
            defaults.set(false, forKey: preferenceKey)
        }
    }
}
