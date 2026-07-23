import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class UsageMonitor: ObservableObject {
    static let safetyBufferKey = "safetyBuffer"
    static let refreshIntervalSecondsKey = "refreshIntervalSeconds"
    static let factorInPausesKey = "factorInPauses"
    static let paceLookbackMinutesKey = "paceLookbackMinutes"
    static let showPreviousWeeklyWindowKey = "showPreviousWeeklyWindow"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var forecast: Forecast?
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var weeklyPaceHours: Double?
    @Published private(set) var weeklyPacePoints: [WeeklyPacePoint] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
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
    private var lastWeeklyPaceCalculationAt: Date?

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
        guard let remaining = snapshot?.mainLimit.window.remainingPercent else { return "—" }
        let displayed = UsagePercentageDisplay.value(
            remainingPercent: remaining,
            showsUsed: UsagePercentageDisplay.showsUsed
        )
        return "\(Int(displayed.rounded()))%"
    }

    var currentWindowSamples: [UsageSample] {
        guard let reset = snapshot?.mainLimit.window.resetsAt else { return [] }
        return samples.filter { $0.resetsAt == reset }.sorted { $0.observedAt < $1.observedAt }
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
        let clampedSeconds = min(max(seconds, 15), 3_600)
        UserDefaults.standard.set(clampedSeconds, forKey: Self.refreshIntervalSecondsKey)
        guard started else { return }
        scheduleRefreshTimer()
    }

    func updateFactorInPauses(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.factorInPausesKey)
        lastWeeklyPaceCalculationAt = nil
        guard let snapshot else { return }
        Task { await updateWeeklyPace(from: snapshot) }
    }

    func updatePaceLookback(minutes: Int) {
        let clampedMinutes = min(max(minutes, 15), 180)
        UserDefaults.standard.set(clampedMinutes, forKey: Self.paceLookbackMinutesKey)
        lastWeeklyPaceCalculationAt = nil
        guard let snapshot else { return }
        Task { await updateWeeklyPace(from: snapshot) }
    }

    func updateShowPreviousWeeklyWindow(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.showPreviousWeeklyWindowKey)
        lastWeeklyPaceCalculationAt = nil
        guard let snapshot else { return }
        Task { await updateWeeklyPace(from: snapshot) }
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
        let historyState = await exchangeHistory()
        apply(historyState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
        let exchangeErrorMessage = historyState.errorMessage
        recalculate()
        persist()

        do {
            let newSnapshot = try await fetchTask.value
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
            guard samples.contains(sample) else {
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
            await updateWeeklyPace(from: newSnapshot)
        } catch let error as CodexClientError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Couldn’t read Codex usage. Try refreshing again."
        }
    }

    func shutdown() {
        refreshTimerCancellable?.cancel()
        client.shutdown()
    }

    private func scheduleRefreshTimer() {
        refreshTimerCancellable?.cancel()

        let defaults = UserDefaults.standard
        let seconds: Int
        if defaults.object(forKey: Self.refreshIntervalSecondsKey) != nil {
            seconds = min(max(defaults.integer(forKey: Self.refreshIntervalSecondsKey), 15), 3_600)
        } else if defaults.object(forKey: "refreshIntervalMinutes") != nil {
            seconds = min(max(defaults.integer(forKey: "refreshIntervalMinutes") * 60, 15), 3_600)
            defaults.set(seconds, forKey: Self.refreshIntervalSecondsKey)
        } else {
            seconds = 60
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
        lastWeeklyPaceCalculationAt = nil
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
            previousStatus: previousStatus
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

    private func updateWeeklyPace(from snapshot: UsageSnapshot) async {
        guard let window = Self.weeklyWindow(in: snapshot) else {
            weeklyPaceHours = nil
            weeklyPacePoints = []
            return
        }
        if let lastWeeklyPaceCalculationAt,
           snapshot.fetchedAt.timeIntervalSince(lastWeeklyPaceCalculationAt) < 60 {
            return
        }
        lastWeeklyPaceCalculationAt = snapshot.fetchedAt

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

        let activity = await CodexActivityReader.loadIntervals(
            since: firstSample.observedAt,
            now: snapshot.fetchedAt
        )
        let refreshSeconds = defaults.object(forKey: Self.refreshIntervalSecondsKey) == nil
            ? 60
            : defaults.integer(forKey: Self.refreshIntervalSecondsKey)
        let tolerance = min(max(TimeInterval(refreshSeconds) * 1.5, 90), 15 * 60)
        let factorInPauses = defaults.object(forKey: Self.factorInPausesKey) == nil
            ? false
            : defaults.bool(forKey: Self.factorInPausesKey)
        let lookbackMinutes = defaults.object(forKey: Self.paceLookbackMinutesKey) == nil
            ? 60
            : min(max(defaults.integer(forKey: Self.paceLookbackMinutesKey), 15), 180)
        let lookback = TimeInterval(lookbackMinutes * 60)
        let calculation = await Task.detached(priority: .utility) {
            let points = WeeklyPaceCalculator.estimateSeries(
                samples: relevantSamples,
                activity: activity,
                now: snapshot.fetchedAt,
                sampleTolerance: tolerance,
                factorInPauses: factorInPauses,
                lookback: lookback
            )
            let current = points.last(where: {
                abs($0.windowResetsAt.timeIntervalSince(window.resetsAt)) <= 5 * 60
            })?.hoursPerWeek
            return (points, current)
        }.value
        weeklyPacePoints = calculation.0
        weeklyPaceHours = calculation.1
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
