import AppKit
import Combine
import Foundation
import OSLog

enum UsageRefreshSchedule {
    static let defaultSeconds = 15
    static let minimumSeconds = 1
    static let maximumSeconds = 3_600
    static let choices = [1, 2, 5, 10, 15, 30] + Array(stride(from: 60, through: 3_600, by: 60))

    static func clamped(_ seconds: Int) -> Int {
        min(max(seconds, minimumSeconds), maximumSeconds)
    }
}

@MainActor
final class UsageMonitor: ObservableObject {
    static let safetyBufferKey = "safetyBuffer"
    static let refreshIntervalSecondsKey = "refreshIntervalSeconds"
    static let factorInPausesKey = "factorInPauses"
    static let showPreviousWeeklyWindowKey = "showPreviousWeeklyWindow"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var forecast: Forecast?
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var weeklyPaceHours: Double?
    @Published private(set) var dailyRuntimeHours: Double?
    @Published private(set) var historicalDailyRuntimeHours: Double?
    @Published private(set) var weeklyPacePoints: [WeeklyPacePoint] = []
    @Published private(set) var activityIntervals: [ActivityInterval] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activityErrorMessage: String?
    @Published private(set) var activityCacheIntegrityFailed = false
    @Published private(set) var usageReadFailed = false
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncErrorMessage: String?

    private static let stateKey = "usageState"
    private static let historyInstallationIDKey = "historyInstallationID"
    private static let historySyncBookmarkKey = "historySyncBookmark"
    private let history: UsageHistory
    private let weeklyHistory: UsageHistory
    private let client = CodexClient()
    private let logger = Logger(
        subsystem: "com.github.thrr87.CodexLimits",
        category: "UsageMonitor"
    )
    private var previousStatus: PaceStatus?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTimerCancellable: AnyCancellable?
    private var started = false
    private var historyPrepared = false
    private var historyUsesFiles = false
    private var configuredSyncDirectory: URL?
    private var historyConnectionActive = false
    private var weeklySamples: [UsageSample] = []
    private var lastHistoryExchangeAt: Date?
    private var lastScheduledActivityWindows: [String: UsageWindow]?
    private var pendingActivitySnapshot: UsageSnapshot?
    private var activityAnalysisTask: Task<Void, Never>?
    private static let maintenanceInterval: TimeInterval = 10 * 60

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            snapshot = state.snapshot
            samples = state.samples
            previousStatus = state.previousStatus
        }

        let installationID: String
        if let existing = defaults.string(forKey: Self.historyInstallationIDKey),
           let uuid = UUID(uuidString: existing) {
            installationID = uuid.uuidString.lowercased()
        } else {
            installationID = UUID().uuidString.lowercased()
            defaults.set(installationID, forKey: Self.historyInstallationIDKey)
        }
        history = UsageHistory(
            localDirectory: Self.historyDirectory(),
            installationID: installationID
        )
        weeklyHistory = UsageHistory(
            localDirectory: Self.weeklyHistoryDirectory(),
            installationID: installationID
        )
        recalculate()

        Task { [weak self] in
            await self?.start()
        }
    }

    var menuBarText: String {
        if activityCacheIntegrityFailed || usageReadFailed { return "-%" }
        guard let remaining = snapshot?.mainLimit.window.remainingPercent else { return "—" }
        let displayed = UsagePercentageDisplay.value(
            remainingPercent: remaining,
            showsUsed: UsagePercentageDisplay.showsUsed
        )
        return "\(Int(displayed.rounded()))%"
    }

    var currentWindowSamples: [UsageSample] {
        guard let reset = snapshot?.mainLimit.window.resetsAt else { return [] }
        return UsageReadingValidation.samples(samples, matchingReset: reset)
    }

    var lastUsageChangeAt: Date? {
        currentWindowSamples.last?.observedAt ?? snapshot?.fetchedAt
    }

    func start() async {
        guard !started else { return }
        started = true

        await prepareHistory()

        scheduleRefreshTimer()

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)

        await refresh()
    }

    func updateRefreshInterval(seconds: Int) {
        let clampedSeconds = UsageRefreshSchedule.clamped(seconds)
        UserDefaults.standard.set(clampedSeconds, forKey: Self.refreshIntervalSecondsKey)
        guard started else { return }
        scheduleRefreshTimer()
    }

    func updateFactorInPauses(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.factorInPausesKey)
        lastScheduledActivityWindows = nil
        guard let snapshot else { return }
        scheduleActivityAnalysisIfNeeded(for: snapshot)
    }

    func updateProratesShortWindows(_ enabled: Bool) {
        UserDefaults.standard.set(
            enabled,
            forKey: EstimatedRuntimeChartPreferences.proratesShortWindowsKey
        )
        lastScheduledActivityWindows = nil
        guard let snapshot else { return }
        scheduleActivityAnalysisIfNeeded(for: snapshot)
    }

    func updateProratingThreshold(minutes: Int) {
        let minutes = EstimatedRuntimeChartPreferences.clampedProratingThreshold(minutes)
        UserDefaults.standard.set(
            minutes,
            forKey: EstimatedRuntimeChartPreferences.proratingThresholdMinutesKey
        )
        lastScheduledActivityWindows = nil
        guard let snapshot else { return }
        scheduleActivityAnalysisIfNeeded(for: snapshot)
    }

    func updateProratingDistance(minutes: Int) {
        let minutes = EstimatedRuntimeChartPreferences.clampedProratingDistance(minutes)
        UserDefaults.standard.set(
            minutes,
            forKey: EstimatedRuntimeChartPreferences.proratingDistanceMinutesKey
        )
        lastScheduledActivityWindows = nil
        guard let snapshot else { return }
        scheduleActivityAnalysisIfNeeded(for: snapshot)
    }

    func updateShowPreviousWeeklyWindow(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.showPreviousWeeklyWindowKey)
        lastScheduledActivityWindows = nil
        guard let snapshot else { return }
        scheduleActivityAnalysisIfNeeded(for: snapshot)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await prepareHistory()
        if !historyUsesFiles {
            let historyState = await history.load(legacySamples: samples)
            apply(historyState)
            historyUsesFiles = historyState.errorMessage == nil
        }

        let fetchTask = Task { try await client.fetch() }
        var exchangeErrorMessage = syncErrorMessage
        if maintenanceIsDue(since: lastHistoryExchangeAt, now: Date()) {
            let historyState = await exchangeHistory()
            apply(historyState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
            exchangeErrorMessage = historyState.errorMessage
            lastHistoryExchangeAt = Date()
            recalculate()
            persist()
        }

        do {
            let newSnapshot = try await fetchTask.value
            usageReadFailed = false
            let window = newSnapshot.mainLimit.window
            let sample = UsageSample(
                observedAt: newSnapshot.fetchedAt,
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt
            )
            let recordedState = await history.record(sample)
            apply(recordedState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
            if recordedState.errorMessage == nil {
                syncErrorMessage = exchangeErrorMessage
            }
            await recordWeeklySample(from: newSnapshot)
            guard samples.contains(sample)
                    || samples.last?.remainingPercent == sample.remainingPercent else {
                logger.info(
                    "Recorded pending remaining percentage increase to \(window.remainingPercent, privacy: .public); reset timestamp \(window.resetsAt.timeIntervalSince1970, privacy: .public)"
                )
                errorMessage = nil
                return
            }
            snapshot = newSnapshot
            errorMessage = nil
            recalculate()
            persist()
            scheduleActivityAnalysisIfNeeded(for: newSnapshot)
        } catch let error as CodexClientError {
            errorMessage = error.localizedDescription
            usageReadFailed = true
        } catch {
            errorMessage = "Couldn’t read Codex usage. Try refreshing again."
            usageReadFailed = true
        }
    }

    func shutdown() {
        refreshTimerCancellable?.cancel()
        activityAnalysisTask?.cancel()
        client.shutdown()
    }

    private func scheduleRefreshTimer() {
        refreshTimerCancellable?.cancel()

        let defaults = UserDefaults.standard
        let seconds: Int
        if defaults.object(forKey: Self.refreshIntervalSecondsKey) != nil {
            seconds = UsageRefreshSchedule.clamped(
                defaults.integer(forKey: Self.refreshIntervalSecondsKey)
            )
        } else if defaults.object(forKey: "refreshIntervalMinutes") != nil {
            seconds = UsageRefreshSchedule.clamped(
                defaults.integer(forKey: "refreshIntervalMinutes") * 60
            )
            defaults.set(seconds, forKey: Self.refreshIntervalSecondsKey)
        } else {
            seconds = UsageRefreshSchedule.defaultSeconds
        }
        refreshTimerCancellable = Timer.publish(
            every: TimeInterval(seconds),
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func updateSafetyBuffer(_ value: Double) {
        recalculate(safetyBuffer: value)
        persist()
    }

    func connectHistoryFolder(_ directory: URL) async {
        await prepareHistory()
        let state = await history.connect(to: directory)
        apply(state)
        historyConnectionActive = state.folderName != nil
        guard historyConnectionActive else { return }

        do {
            let bookmark = try directory.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.historySyncBookmarkKey)
            configuredSyncDirectory = directory
            syncFolderName = directory.lastPathComponent
        } catch {
            _ = await history.disconnect()
            configuredSyncDirectory = nil
            historyConnectionActive = false
            syncFolderName = nil
            syncErrorMessage = "Couldn’t remember the history folder. Choose it again."
        }
    }

    func stopHistorySync() async {
        UserDefaults.standard.removeObject(forKey: Self.historySyncBookmarkKey)
        configuredSyncDirectory = nil
        historyConnectionActive = false
        apply(await history.disconnect())
    }

    func resetHistory() async {
        apply(await history.reset())
        _ = await weeklyHistory.reset()
        weeklySamples = []
        weeklyPaceHours = nil
        weeklyPacePoints = []
        lastScheduledActivityWindows = nil
        previousStatus = nil
        recalculate()
        persist()
    }

    private func recalculate(safetyBuffer: Double? = nil) {
        guard let snapshot else { return }
        let storedBuffer = UserDefaults.standard.object(forKey: Self.safetyBufferKey) as? Double
        let buffer = safetyBuffer ?? storedBuffer ?? 3
        let result = ForecastEngine.evaluate(
            window: snapshot.mainLimit.window,
            samples: samples,
            tokenHistory: snapshot.tokenHistory,
            safetyBuffer: buffer,
            now: snapshot.fetchedAt,
            previousStatus: previousStatus,
            runtimePercentPerDay: runtimePercentPerDay,
            historicalRuntimePercentPerDay: historicalRuntimePercentPerDay
        )
        forecast = result
        previousStatus = result.status
    }

    private func persist() {
        let state = StoredState(
            snapshot: snapshot,
            samples: historyUsesFiles ? [] : samples,
            previousStatus: previousStatus
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func prepareHistory() async {
        guard !historyPrepared else { return }
        historyPrepared = true

        let state = await history.load(legacySamples: samples)
        apply(state)
        weeklySamples = UsageReadingValidation.removingImplausibleIncreases(
            from: await weeklyHistory.load(legacySamples: samples).samples
        )
        historyUsesFiles = state.errorMessage == nil
        if historyUsesFiles {
            persist()
        }

        guard let bookmark = UserDefaults.standard.data(forKey: Self.historySyncBookmarkKey) else {
            return
        }
        let directory: URL
        var isStale = false
        do {
            directory = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.historySyncBookmarkKey)
            syncErrorMessage = "Couldn’t reopen the history folder. Choose it again."
            return
        }

        configuredSyncDirectory = directory
        let connectedState = await history.connect(to: directory)
        historyConnectionActive = connectedState.folderName != nil
        apply(connectedState, configuredFolderName: directory.lastPathComponent)
        if isStale, historyConnectionActive {
            do {
                let refreshed = try directory.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: Self.historySyncBookmarkKey)
            } catch {
                syncErrorMessage = "Couldn’t update the saved history folder."
            }
        }
    }

    private func exchangeHistory() async -> UsageHistory.State {
        if let configuredSyncDirectory, !historyConnectionActive {
            let state = await history.connect(to: configuredSyncDirectory)
            historyConnectionActive = state.folderName != nil
            return state
        }
        return await history.synchronize()
    }

    private func apply(
        _ state: UsageHistory.State,
        configuredFolderName: String? = nil
    ) {
        samples = UsageReadingValidation.removingImplausibleIncreases(from: state.samples)
        syncFolderName = state.folderName ?? configuredFolderName
        syncErrorMessage = state.errorMessage
    }

    private static func historyDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    private static func weeklyHistoryDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent("WeeklyHistory", isDirectory: true)
    }

    private func recordWeeklySample(from snapshot: UsageSnapshot) async {
        guard let window = Self.weeklyWindow(in: snapshot) else { return }
        let sample = UsageSample(
            observedAt: snapshot.fetchedAt,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt
        )

        if weeklySamples.isEmpty {
            weeklySamples = UsageReadingValidation.removingImplausibleIncreases(
                from: await weeklyHistory.load(legacySamples: samples + [sample]).samples
            )
        } else {
            weeklySamples = UsageReadingValidation.removingImplausibleIncreases(
                from: await weeklyHistory.record(sample).samples
            )
        }
    }

    private func updateWeeklyPace(from snapshot: UsageSnapshot) async throws {
        defer {
            recalculate()
            persist()
        }
        guard let window = Self.weeklyWindow(in: snapshot) else {
            weeklyPaceHours = nil
            weeklyPacePoints = []
            return
        }
        let defaults = UserDefaults.standard
        let showPreviousWindow = defaults.object(forKey: Self.showPreviousWeeklyWindowKey) == nil
            ? true
            : defaults.bool(forKey: Self.showPreviousWeeklyWindowKey)
        let currentSamples = weeklySamples.filter {
            abs($0.resetsAt.timeIntervalSince(window.resetsAt)) <= 5 * 60
        }
        let firstCurrentDate = currentSamples.map(\.observedAt).min() ?? window.startsAt
        let previousCandidates = weeklySamples.filter {
            $0.observedAt < firstCurrentDate
                && abs($0.resetsAt.timeIntervalSince(window.resetsAt)) > 5 * 60
        }
        let previousReset = showPreviousWindow
            ? previousCandidates
                .filter { candidate in
                    Set(previousCandidates.lazy.filter {
                        abs($0.resetsAt.timeIntervalSince(candidate.resetsAt)) <= 5 * 60
                    }.map(\.remainingPercent)).count > 1
                }
                .max(by: { $0.observedAt < $1.observedAt })?
                .resetsAt
            : nil
        let relevantSamples = weeklySamples.filter { sample in
            let isCurrent = abs(sample.resetsAt.timeIntervalSince(window.resetsAt)) <= 5 * 60
            let isPrevious = previousReset.map { reset in
                abs(sample.resetsAt.timeIntervalSince(reset)) <= 5 * 60
            } ?? false
            return isCurrent || isPrevious
        }
        guard let firstSample = relevantSamples.min(by: { $0.observedAt < $1.observedAt }) else {
            weeklyPaceHours = nil
            weeklyPacePoints = []
            return
        }

        let activity = try await CodexActivityReader.loadIntervals(
            since: firstSample.observedAt,
            now: snapshot.fetchedAt
        )
        activityIntervals = activity
        let factorInPauses = defaults.object(forKey: Self.factorInPausesKey) == nil
            ? false
            : defaults.bool(forKey: Self.factorInPausesKey)
        let proratesShortWindows = defaults.object(
            forKey: EstimatedRuntimeChartPreferences.proratesShortWindowsKey
        ) == nil || defaults.bool(
            forKey: EstimatedRuntimeChartPreferences.proratesShortWindowsKey
        )
        let thresholdMinutes = defaults.object(
            forKey: EstimatedRuntimeChartPreferences.proratingThresholdMinutesKey
        ) == nil
            ? EstimatedRuntimeChartPreferences.defaultProratingThresholdMinutes
            : EstimatedRuntimeChartPreferences.clampedProratingThreshold(defaults.integer(
                forKey: EstimatedRuntimeChartPreferences.proratingThresholdMinutesKey
            ))
        let distanceMinutes = defaults.object(
            forKey: EstimatedRuntimeChartPreferences.proratingDistanceMinutesKey
        ) == nil
            ? EstimatedRuntimeChartPreferences.defaultProratingDistanceMinutes
            : EstimatedRuntimeChartPreferences.clampedProratingDistance(defaults.integer(
                forKey: EstimatedRuntimeChartPreferences.proratingDistanceMinutesKey
            ))
        let calculation = await Task.detached(priority: .utility) {
            let points = WeeklyPaceCalculator.estimateSeries(
                samples: relevantSamples,
                activity: activity,
                now: snapshot.fetchedAt,
                factorInPauses: factorInPauses,
                proratesShortWindows: proratesShortWindows,
                proratingThreshold: TimeInterval(thresholdMinutes * 60),
                proratingDistance: TimeInterval(max(distanceMinutes, thresholdMinutes) * 60)
            )
            let current = points.last(where: {
                abs($0.windowResetsAt.timeIntervalSince(window.resetsAt)) <= 5 * 60
            })?.hoursPerWeek
            return (points, current)
        }.value
        weeklyPacePoints = calculation.0
        weeklyPaceHours = calculation.1
    }

    private var runtimePercentPerDay: Double? {
        runtimePercentPerDay(for: dailyRuntimeHours)
    }

    private var historicalRuntimePercentPerDay: Double? {
        runtimePercentPerDay(for: historicalDailyRuntimeHours)
    }

    private func runtimePercentPerDay(for hours: Double?) -> Double? {
        guard let hours,
              let weeklyPaceHours,
              weeklyPaceHours.isFinite,
              weeklyPaceHours > 0 else {
            return nil
        }
        return hours / weeklyPaceHours * 100
    }

    private func updateDailyRuntime(now: Date) async throws {
        guard let windows = DailyRuntimeCalculator.completedDayWindows(
            now: now,
            dayCount: DailyRuntimeCalculator.historicalDayCount
        ),
              let first = windows.first else {
            dailyRuntimeHours = nil
            historicalDailyRuntimeHours = nil
            return
        }
        let activity = try await CodexActivityReader.loadIntervals(
            since: first.start,
            now: now
        )
        activityIntervals = WeeklyPaceCalculator.merged(
            activityIntervals + activity,
            joiningGapsUpTo: 0
        )
        dailyRuntimeHours = DailyRuntimeCalculator.averageRecentDayHours(
            activity: activity,
            now: now
        )
        historicalDailyRuntimeHours = DailyRuntimeCalculator.interquartileMeanCompletedDayHours(
            activity: activity,
            now: now
        )
    }

    private func scheduleActivityAnalysisIfNeeded(for snapshot: UsageSnapshot) {
        let windows = Dictionary(uniqueKeysWithValues: ([snapshot.mainLimit] + snapshot.otherLimits).map {
            ($0.id, $0.window)
        })
        guard activityWindowsChanged(from: lastScheduledActivityWindows, to: windows) else { return }

        lastScheduledActivityWindows = windows
        pendingActivitySnapshot = snapshot
        startPendingActivityAnalysis()
    }

    private func startPendingActivityAnalysis() {
        guard activityAnalysisTask == nil,
              let snapshot = pendingActivitySnapshot else { return }
        pendingActivitySnapshot = nil

        activityAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.updateDailyRuntime(now: snapshot.fetchedAt)
                try await self.updateWeeklyPace(from: snapshot)
                self.activityCacheIntegrityFailed = false
                self.activityErrorMessage = nil
            } catch {
                self.weeklyPaceHours = nil
                self.weeklyPacePoints = []
                self.dailyRuntimeHours = nil
                self.historicalDailyRuntimeHours = nil
                self.activityCacheIntegrityFailed = error is CodexActivityReaderError
                self.activityErrorMessage = error.localizedDescription
                self.logger.error("Activity analysis failed: \(error.localizedDescription, privacy: .public)")
            }
            self.activityAnalysisTask = nil
            self.startPendingActivityAnalysis()
        }
    }

    private func activityWindowsChanged(
        from previous: [String: UsageWindow]?,
        to current: [String: UsageWindow]
    ) -> Bool {
        guard let previous, Set(previous.keys) == Set(current.keys) else { return true }
        return current.contains { id, window in
            guard let oldWindow = previous[id] else { return true }
            return window.remainingPercent != oldWindow.remainingPercent
                || !UsageReadingValidation.isSameWindow(
                    resetsAt: window.resetsAt,
                    previousReset: oldWindow.resetsAt
                )
        }
    }

    private func maintenanceIsDue(since lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= Self.maintenanceInterval
    }

    private static func weeklyWindow(in snapshot: UsageSnapshot) -> UsageWindow? {
        ([snapshot.mainLimit] + snapshot.otherLimits)
            .first { $0.limitId == "codex" && $0.window.durationMinutes == 10_080 }?
            .window
    }
}

private struct StoredState: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
