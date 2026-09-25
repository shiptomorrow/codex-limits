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
    static let includeSubagentRuntimeKey = "includeSubagentRuntime"
    static let factorInPausesKey = "factorInPauses"
    static let showPreviousWeeklyWindowKey = "showPreviousWeeklyWindow"
    static let remoteSessionsEnabledKey = "remoteSessionsEnabled"
    static let remoteSSHProfilesKey = "remoteSSHProfiles"
    static let serverUsageLogSSHProfilesKey = "serverUsageLogSSHProfiles"
    private static let serverUsageLogCursorsKey = "serverUsageLogCursors"
    private static let serverUsageLogScriptHashesKey = "serverUsageLogScriptHashes"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var forecast: Forecast?
    /// Samples for the window shown as the main limit.
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var selectedLimitWindow = UsageLimitWindow.current
    /// Windows the service currently reports data for.
    @Published private(set) var availableLimitWindows: [UsageLimitWindow] = []
    /// The window actually shown, which falls back from the selection when it has no data.
    @Published private(set) var displayedLimitWindow: UsageLimitWindow?
    @Published private(set) var weeklyPaceHours: Double?
    @Published private(set) var dailyRuntimeHours: Double?
    @Published private(set) var historicalDailyRuntimeHours: Double?
    @Published private(set) var weeklyPacePoints: [WeeklyPacePoint] = []
    @Published private(set) var activityIntervals: [ActivityInterval] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAnalyzingActivity = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activityErrorMessage: String?
    @Published private(set) var remoteActivityErrorMessage: String?
    @Published private(set) var usageReadFailed = false
    @Published private(set) var syncFolderName: String?
    @Published private(set) var syncErrorMessage: String?
    @Published private(set) var serverUsageLogStatuses: [String: ServerUsageLogStatus] = [:]

    private static let historyInstallationIDKey = "historyInstallationID"
    let provider: UsageProvider
    private let stateKey: String
    private let historySyncBookmarkKey: String
    private let history: UsageHistory
    private let weeklyHistory: UsageHistory
    private let client: any UsageClient
    private let logger = Logger(
        subsystem: "com.github.thrr87.CodexLimits",
        category: "UsageMonitor"
    )
    private var previousStatus: PaceStatus?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTimerCancellable: AnyCancellable?
    private var refreshInterval = TimeInterval(UsageRefreshSchedule.defaultSeconds)
    /// Last successful read or rate-limited attempt. Servers checking the same account cause
    /// rate limits here, so those still count as this Mac reading usage.
    private var lastUsageReadAt: Date?
    private var started = false
    private var isShutDown = false
    private var historyPrepared = false
    private var historyUsesFiles = false
    private var configuredSyncDirectory: URL?
    private var historyConnectionActive = false
    /// The service's snapshot before `selectedLimitWindow` is applied.
    private var fetchedSnapshot: UsageSnapshot?
    private var fiveHourSamples: [UsageSample] = []
    private var weeklySamples: [UsageSample] = []
    private var lastHistoryExchangeAt: Date?
    private var lastScheduledActivityWindows: [String: UsageWindow]?
    private var pendingActivitySnapshot: UsageSnapshot?
    private var activityAnalysisTask: Task<Void, Never>?
    private var remoteActivityRetryTask: Task<Void, Never>?
    private var rateLimitRetryTask: Task<Void, Never>?
    private var serverUsageLogTimerCancellable: AnyCancellable?
    private var isImportingServerUsageLogs = false
    private var cachedRemoteActivity: (
        profiles: [String],
        includesSubagents: Bool,
        since: Date,
        now: Date,
        result: RemoteCodexActivityResult
    )?
    private static let maintenanceInterval: TimeInterval = 10 * 60

    init(provider: UsageProvider = .current) {
        self.provider = provider
        stateKey = provider.storageKey("usageState")
        historySyncBookmarkKey = provider.storageKey("historySyncBookmark")
        client = switch provider {
        case .codex: CodexClient()
        case .claude: ClaudeClient()
        }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: stateKey),
           let state = try? JSONDecoder().decode(StoredState.self, from: data) {
            fetchedSnapshot = state.snapshot
            fiveHourSamples = state.samples.filter(UsageLimitWindow.isFiveHourSample)
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
            localDirectory: Self.historyDirectory(for: provider),
            installationID: installationID
        )
        weeklyHistory = UsageHistory(
            localDirectory: Self.weeklyHistoryDirectory(for: provider),
            installationID: installationID
        )
        applyLimitWindowSelection()
        recalculate()

        Task { [weak self] in
            await self?.start()
        }
    }

    var isProcessing: Bool { isRefreshing || isAnalyzingActivity }

    var menuBarText: String {
        if usageReadFailed { return "-%" }
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

    var historicalUsageWindows: [HistoricalUsageWindow] {
        guard let currentWindow = snapshot?.mainLimit.window else { return [] }
        return UsageReadingValidation.historicalWindows(in: samples, before: currentWindow)
    }

    var lastUsageChangeAt: Date? {
        currentWindowSamples.last?.observedAt ?? snapshot?.fetchedAt
    }

    func start() async {
        guard !started else { return }
        started = true

        await prepareHistory()
        guard !isShutDown else { return }

        // Pace only needs the weekly window, so start from the saved reading
        // rather than waiting for a fetch that may be rate limited.
        if let saved = snapshot,
           let weeklyWindow = Self.weeklyWindow(in: saved),
           weeklyWindow.resetsAt > Date() {
            scheduleActivityAnalysisIfNeeded(for: saved.refetched(at: Date()))
        }

        scheduleRefreshTimer()
        serverUsageLogTimerCancellable = Timer.publish(
            every: ServerUsageLog.importInterval,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task { @MainActor in await self?.importServerUsageLogs() }
        }

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refresh()
                    await self?.importServerUsageLogs()
                }
            }
            .store(in: &cancellables)

        await refresh()
        await importServerUsageLogs()
    }

    func selectLimitWindow(_ window: UsageLimitWindow) {
        guard window != selectedLimitWindow else { return }
        UserDefaults.standard.set(window.rawValue, forKey: UsageLimitWindow.preferenceKey)
        selectedLimitWindow = window
        // Pace status hysteresis belongs to the previously shown window.
        previousStatus = nil
        applyLimitWindowSelection()
        recalculate()
        persist()
    }

    private func applyLimitWindowSelection() {
        snapshot = fetchedSnapshot.map(selectedLimitWindow.applied(to:))
        availableLimitWindows = fetchedSnapshot.map(UsageLimitWindow.available(in:)) ?? []
        displayedLimitWindow = snapshot.flatMap { snapshot in
            UsageLimitWindow.allCases.first {
                $0.durationMinutes == snapshot.mainLimit.window.durationMinutes
            }
        }
        selectDisplayedSamples()
    }

    private func selectDisplayedSamples() {
        samples = snapshot?.mainLimit.window.durationMinutes == UsageLimitWindow.weekly.durationMinutes
            ? weeklySamples
            : fiveHourSamples
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

    func updateIncludeSubagentRuntime(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.includeSubagentRuntimeKey)
        activityIntervals = []
        remoteActivitySettingsChanged()
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

    func updatePercentagePointLookback(_ points: Int) {
        let points = EstimatedRuntimeChartPreferences.clampedPercentagePointLookback(points)
        UserDefaults.standard.set(
            points,
            forKey: EstimatedRuntimeChartPreferences.percentagePointLookbackKey
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

    var remoteSSHProfiles: [String] {
        UserDefaults.standard.stringArray(forKey: Self.remoteSSHProfilesKey) ?? []
    }

    func updateRemoteSessionsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.remoteSessionsEnabledKey)
        remoteActivitySettingsChanged()
    }

    func updateRemoteSSHProfiles(_ profiles: Set<String>) {
        UserDefaults.standard.set(profiles.sorted(), forKey: Self.remoteSSHProfilesKey)
        remoteActivitySettingsChanged()
    }

    var serverUsageLogSSHProfiles: [String] {
        UserDefaults.standard.stringArray(
            forKey: provider.storageKey(Self.serverUsageLogSSHProfilesKey)
        ) ?? []
    }

    /// Installs or removes the usage logger on `profile`, which keeps recording while this Mac is off.
    func setServerUsageLogging(_ enabled: Bool, on profile: String) async {
        var profiles = Set(serverUsageLogSSHProfiles)
        if enabled {
            profiles.insert(profile)
        } else {
            profiles.remove(profile)
        }
        UserDefaults.standard.set(
            profiles.sorted(),
            forKey: provider.storageKey(Self.serverUsageLogSSHProfilesKey)
        )
        setServerUsageLogScriptHash(nil, for: profile)

        if enabled {
            serverUsageLogStatuses[profile] = ServerUsageLogStatus(text: "Setting up logger…", isError: false)
            await importServerUsageLog(from: profile)
        } else {
            serverUsageLogStatuses[profile] = ServerUsageLogStatus(text: "Removing logger…", isError: false)
            do {
                try await ServerUsageLog.uninstall(profile: profile, provider: provider)
                // The toggle may have been turned back on while the logger was being removed.
                if !serverUsageLogSSHProfiles.contains(profile) {
                    serverUsageLogStatuses[profile] = nil
                }
            } catch {
                serverUsageLogStatuses[profile] = ServerUsageLogStatus(
                    text: "Couldn’t remove the logger: \(Self.message(for: error))",
                    isError: true
                )
            }
        }
    }

    /// Pulls usage the enabled servers logged since the last import into history.
    func importServerUsageLogs() async {
        guard !isImportingServerUsageLogs, !isShutDown else { return }
        isImportingServerUsageLogs = true
        defer { isImportingServerUsageLogs = false }
        await prepareHistory()
        for profile in serverUsageLogSSHProfiles {
            await importServerUsageLog(from: profile)
        }
    }

    /// Servers check less often while this Mac reads usage at least as often as they would.
    private var macLoggingUntil: Date? {
        let now = Date()
        guard refreshInterval <= ServerUsageLog.checkInterval(for: provider),
              let lastUsageReadAt,
              now.timeIntervalSince(lastUsageReadAt) < ServerUsageLog.macReadFreshness else { return nil }
        return now.addingTimeInterval(ServerUsageLog.macLoggingLease)
    }

    private func importServerUsageLog(from profile: String) async {
        guard !isShutDown else { return }
        do {
            let currentScript = ServerUsageLog.scriptHash
            var installed: ServerUsageLogExport?
            if currentScript == nil || serverUsageLogScriptHash(for: profile) != currentScript {
                installed = try await ServerUsageLog.install(profile: profile, provider: provider)
                setServerUsageLogScriptHash(currentScript, for: profile)
            }
            var export = try await ServerUsageLog.export(
                profile: profile,
                provider: provider,
                since: serverUsageLogCursor(for: profile),
                macLoggingUntil: macLoggingUntil
            )
            if !export.installed, installed == nil {
                // The cron entry was removed on the host; schedule it again.
                _ = try await ServerUsageLog.install(profile: profile, provider: provider)
                setServerUsageLogScriptHash(currentScript, for: profile)
                export = try await ServerUsageLog.export(
                    profile: profile,
                    provider: provider,
                    since: serverUsageLogCursor(for: profile),
                    macLoggingUntil: macLoggingUntil
                )
            }
            guard serverUsageLogSSHProfiles.contains(profile) else { return }
            await importServerSamples(export, from: profile)
            serverUsageLogStatuses[profile] = ServerUsageLogStatus(export: export, provider: provider, now: Date())
        } catch {
            guard serverUsageLogSSHProfiles.contains(profile) else { return }
            serverUsageLogStatuses[profile] = ServerUsageLogStatus(
                text: "Couldn’t reach the logger: \(Self.message(for: error))",
                isError: true
            )
        }
    }

    private func importServerSamples(_ export: ServerUsageLogExport, from profile: String) async {
        let writer = ServerUsageLog.historyWriter(for: profile)
        if !export.fiveHourSamples.isEmpty {
            let state = await history.importSamples(export.fiveHourSamples, writer: writer)
            apply(state, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
        }
        if !export.weeklySamples.isEmpty {
            weeklySamples = UsageReadingValidation.removingImplausibleIncreases(
                from: await weeklyHistory.importSamples(export.weeklySamples, writer: writer).samples
            )
            selectDisplayedSamples()
        }
        if let newest = export.newestEntryTime {
            setServerUsageLogCursor(newest, for: profile)
        }
        guard !export.fiveHourSamples.isEmpty || !export.weeklySamples.isEmpty else { return }
        logger.info(
            "Imported \(export.fiveHourSamples.count + export.weeklySamples.count, privacy: .public) server usage samples from \(profile, privacy: .public)"
        )
        recalculate()
        persist()
        lastScheduledActivityWindows = nil
        if let snapshot {
            scheduleActivityAnalysisIfNeeded(for: snapshot)
        }
    }

    private func serverUsageLogCursor(for profile: String) -> TimeInterval {
        let cursors = UserDefaults.standard.dictionary(
            forKey: provider.storageKey(Self.serverUsageLogCursorsKey)
        )
        return (cursors?[profile] as? Double) ?? 0
    }

    private func setServerUsageLogCursor(_ time: TimeInterval, for profile: String) {
        let key = provider.storageKey(Self.serverUsageLogCursorsKey)
        var cursors = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        cursors[profile] = max(time, serverUsageLogCursor(for: profile))
        UserDefaults.standard.set(cursors, forKey: key)
    }

    private func serverUsageLogScriptHash(for profile: String) -> String? {
        UserDefaults.standard.dictionary(
            forKey: provider.storageKey(Self.serverUsageLogScriptHashesKey)
        )?[profile] as? String
    }

    private func setServerUsageLogScriptHash(_ hash: String?, for profile: String) {
        let key = provider.storageKey(Self.serverUsageLogScriptHashesKey)
        var hashes = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        hashes[profile] = hash
        UserDefaults.standard.set(hashes, forKey: key)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func refresh() async {
        guard !isRefreshing, !isShutDown else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await prepareHistory()
        if !historyUsesFiles {
            let historyState = await history.load(legacySamples: fiveHourSamples)
            apply(historyState)
            historyUsesFiles = historyState.errorMessage == nil
        }

        let fetchTask = Task { try await client.fetch() }
        defer { scheduleRateLimitRetry() }
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
            lastUsageReadAt = Date()
            if let fiveHourWindow = UsageLimitWindow.fiveHour.reading(in: newSnapshot)?.window {
                let recordedState = await history.record(UsageSample(
                    observedAt: newSnapshot.fetchedAt,
                    remainingPercent: fiveHourWindow.remainingPercent,
                    resetsAt: fiveHourWindow.resetsAt
                ))
                apply(recordedState, configuredFolderName: configuredSyncDirectory?.lastPathComponent)
                if recordedState.errorMessage == nil {
                    syncErrorMessage = exchangeErrorMessage
                }
            }
            await recordWeeklySample(from: newSnapshot)

            let displayedSnapshot = selectedLimitWindow.applied(to: newSnapshot)
            let window = displayedSnapshot.mainLimit.window
            let sample = UsageSample(
                observedAt: newSnapshot.fetchedAt,
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt
            )
            let displayedSamples = window.durationMinutes == UsageLimitWindow.weekly.durationMinutes
                ? weeklySamples
                : fiveHourSamples
            guard displayedSamples.contains(sample)
                    || displayedSamples.last?.remainingPercent == sample.remainingPercent else {
                logger.info(
                    "Recorded pending remaining percentage increase to \(window.remainingPercent, privacy: .public); reset timestamp \(window.resetsAt.timeIntervalSince1970, privacy: .public)"
                )
                errorMessage = nil
                return
            }
            fetchedSnapshot = newSnapshot
            applyLimitWindowSelection()
            errorMessage = nil
            recalculate()
            persist()
            scheduleActivityAnalysisIfNeeded(for: displayedSnapshot)
        } catch let error as LocalizedError where error.errorDescription != nil {
            if error as? ClaudeClientError == .rateLimited {
                lastUsageReadAt = Date()
            }
            errorMessage = error.errorDescription
            usageReadFailed = true
        } catch {
            errorMessage = "Couldn’t read \(provider.displayName) usage. Try refreshing again."
            usageReadFailed = true
        }
    }

    func shutdown() {
        isShutDown = true
        refreshTimerCancellable?.cancel()
        serverUsageLogTimerCancellable?.cancel()
        rateLimitRetryTask?.cancel()
        activityAnalysisTask?.cancel()
        remoteActivityRetryTask?.cancel()
        client.shutdown()
    }

    private func remoteActivitySettingsChanged() {
        remoteActivityRetryTask?.cancel()
        remoteActivityRetryTask = nil
        cachedRemoteActivity = nil
        remoteActivityErrorMessage = nil
        lastScheduledActivityWindows = nil
        guard let snapshot else { return }
        scheduleActivityAnalysisIfNeeded(for: snapshot)
    }

    /// Retries at the client's backoff time, which can be sooner than the refresh interval.
    private func scheduleRateLimitRetry() {
        rateLimitRetryTask?.cancel()
        rateLimitRetryTask = nil
        guard !isShutDown, let retryAt = client.retryAt else { return }
        let delay = retryAt.timeIntervalSinceNow
        guard delay > 0 else { return }
        rateLimitRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.rateLimitRetryTask = nil
            await self.refresh()
        }
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
        refreshInterval = TimeInterval(seconds)
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
            UserDefaults.standard.set(bookmark, forKey: historySyncBookmarkKey)
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
        UserDefaults.standard.removeObject(forKey: historySyncBookmarkKey)
        configuredSyncDirectory = nil
        historyConnectionActive = false
        apply(await history.disconnect())
    }

    func resetHistory() async {
        apply(await history.reset())
        _ = await weeklyHistory.reset()
        weeklySamples = []
        selectDisplayedSamples()
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
        // Runtime rates are percentages of the weekly allowance, so they don't apply to the 5-hour window.
        let isWeekly = snapshot.mainLimit.window.durationMinutes == UsageLimitWindow.weekly.durationMinutes
        let result = ForecastEngine.evaluate(
            window: snapshot.mainLimit.window,
            samples: samples,
            tokenHistory: snapshot.tokenHistory,
            safetyBuffer: buffer,
            now: snapshot.fetchedAt,
            previousStatus: previousStatus,
            runtimePercentPerDay: isWeekly ? runtimePercentPerDay : nil,
            historicalRuntimePercentPerDay: isWeekly ? historicalRuntimePercentPerDay : nil
        )
        forecast = result
        previousStatus = result.status
    }

    private func persist() {
        let state = StoredState(
            snapshot: fetchedSnapshot,
            samples: historyUsesFiles ? [] : fiveHourSamples,
            previousStatus: previousStatus
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    private func prepareHistory() async {
        guard !historyPrepared else { return }
        historyPrepared = true

        let state = await history.load(legacySamples: fiveHourSamples)
        apply(state)
        weeklySamples = UsageReadingValidation.removingImplausibleIncreases(
            from: await weeklyHistory.load().samples
        )
        selectDisplayedSamples()
        historyUsesFiles = state.errorMessage == nil
        if historyUsesFiles {
            persist()
        }

        guard let bookmark = UserDefaults.standard.data(forKey: historySyncBookmarkKey) else {
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
            UserDefaults.standard.removeObject(forKey: historySyncBookmarkKey)
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
                UserDefaults.standard.set(refreshed, forKey: historySyncBookmarkKey)
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
        fiveHourSamples = UsageReadingValidation.removingImplausibleIncreases(
            from: state.samples.filter(UsageLimitWindow.isFiveHourSample)
        )
        selectDisplayedSamples()
        syncFolderName = state.folderName ?? configuredFolderName
        syncErrorMessage = state.errorMessage
    }

    private static func historyDirectory(for provider: UsageProvider) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent(provider.storageKey("History"), isDirectory: true)
    }

    private static func weeklyHistoryDirectory(for provider: UsageProvider) -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.github.thrr87.CodexLimits", isDirectory: true)
            .appendingPathComponent(provider.storageKey("WeeklyHistory"), isDirectory: true)
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
                from: await weeklyHistory.load(legacySamples: [sample]).samples
            )
        } else {
            weeklySamples = UsageReadingValidation.removingImplausibleIncreases(
                from: await weeklyHistory.record(sample).samples
            )
        }
        selectDisplayedSamples()
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

        let activity = try await loadActivityIntervals(
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
        let percentagePointLookback = defaults.object(
            forKey: EstimatedRuntimeChartPreferences.percentagePointLookbackKey
        ) == nil
            ? EstimatedRuntimeChartPreferences.defaultPercentagePointLookback
            : EstimatedRuntimeChartPreferences.clampedPercentagePointLookback(defaults.integer(
                forKey: EstimatedRuntimeChartPreferences.percentagePointLookbackKey
            ))
        let calculation = await Task.detached(priority: .utility) {
            let points = WeeklyPaceCalculator.estimateSeries(
                samples: relevantSamples,
                activity: activity,
                now: snapshot.fetchedAt,
                factorInPauses: factorInPauses,
                proratesShortWindows: proratesShortWindows,
                proratingThreshold: TimeInterval(thresholdMinutes * 60),
                proratingDistance: TimeInterval(max(distanceMinutes, thresholdMinutes) * 60),
                percentagePointLookback: percentagePointLookback
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
        let activity = try await loadActivityIntervals(
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

    private func loadActivityIntervals(since: Date, now: Date) async throws -> [ActivityInterval] {
        let defaults = UserDefaults.standard
        let includesSubagents = defaults.bool(forKey: Self.includeSubagentRuntimeKey)
        let local = switch provider {
        case .codex:
            try await CodexActivityReader.loadIntervals(
                since: since, now: now, includesSubagents: includesSubagents
            )
        case .claude:
            try await ClaudeActivityReader.loadIntervals(
                since: since, now: now, includesSubagents: includesSubagents
            )
        }
        guard defaults.bool(forKey: Self.remoteSessionsEnabledKey) else {
            remoteActivityErrorMessage = nil
            return local
        }

        let profiles = remoteSSHProfiles
        guard !profiles.isEmpty else {
            remoteActivityErrorMessage = "Choose at least one SSH profile in Settings."
            return local
        }

        let remote: RemoteCodexActivityResult
        if let cachedRemoteActivity,
           cachedRemoteActivity.profiles == profiles,
           cachedRemoteActivity.includesSubagents == includesSubagents,
           cachedRemoteActivity.since <= since,
           cachedRemoteActivity.now == now {
            remote = cachedRemoteActivity.result
        } else {
            remote = await RemoteCodexActivityReader.loadIntervals(
                provider: provider,
                profiles: profiles,
                since: since,
                now: now,
                includesSubagents: includesSubagents
            )
            cachedRemoteActivity = (profiles, includesSubagents, since, now, remote)
        }
        remoteActivityErrorMessage = remote.errors.isEmpty
            ? nil
            : "Remote sessions: \(remote.errors.joined(separator: "; "))"
        if remote.errors.isEmpty {
            remoteActivityRetryTask?.cancel()
            remoteActivityRetryTask = nil
        } else {
            scheduleRemoteActivityRetryIfNeeded()
        }
        return local + remote.intervals.filter { $0.end >= since && $0.start <= now }
    }

    private func scheduleRemoteActivityRetryIfNeeded() {
        guard remoteActivityRetryTask == nil else { return }
        logger.info(
            "Scheduling remote SSH retry in \(Int(RemoteSSHPolicy.retryDelay), privacy: .public) seconds"
        )
        remoteActivityRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(RemoteSSHPolicy.retryDelay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.remoteActivityRetryTask = nil
            guard UserDefaults.standard.bool(forKey: Self.remoteSessionsEnabledKey),
                  !self.remoteSSHProfiles.isEmpty,
                  let snapshot = self.snapshot else { return }

            self.logger.info("Retrying remote SSH activity after an earlier failure")
            self.cachedRemoteActivity = nil
            self.lastScheduledActivityWindows = nil
            self.scheduleActivityAnalysisIfNeeded(for: snapshot)
        }
    }

    private func scheduleActivityAnalysisIfNeeded(for snapshot: UsageSnapshot) {
        let windows = Dictionary(uniqueKeysWithValues: ([snapshot.mainLimit] + snapshot.otherLimits).map {
            ($0.id, $0.window)
        })
        guard activityWindowsChanged(from: lastScheduledActivityWindows, to: windows) else { return }

        lastScheduledActivityWindows = windows
        pendingActivitySnapshot = snapshot
        isAnalyzingActivity = true
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
                self.activityErrorMessage = nil
            } catch {
                self.weeklyPaceHours = nil
                self.weeklyPacePoints = []
                self.dailyRuntimeHours = nil
                self.historicalDailyRuntimeHours = nil
                self.activityErrorMessage = error.localizedDescription
                self.logger.error("Activity analysis failed: \(error.localizedDescription, privacy: .public)")
            }
            self.activityAnalysisTask = nil
            self.isAnalyzingActivity = self.pendingActivitySnapshot != nil
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
            .first {
                $0.limitId == snapshot.mainLimit.limitId && $0.window.durationMinutes == 10_080
            }?
            .window
    }
}

struct ServerUsageLogStatus: Equatable {
    let text: String
    let isError: Bool

    init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }

    init(export: ServerUsageLogExport, provider: UsageProvider, now: Date) {
        let time = { (date: Date) in
            Calendar.current.isDate(date, inSameDayAs: now)
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(date: .abbreviated, time: .shortened)
        }
        var parts: [String]
        var isError = false
        if let lastError = export.lastError, let lastRunAt = export.lastRunAt {
            parts = ["Logger error at \(time(lastRunAt)): \(lastError)"]
            isError = true
        } else if let lastRunAt = export.lastRunAt {
            let macIsLogging = export.macLoggingUntil.map { $0 > now } ?? false
            let staleInterval = macIsLogging
                ? ServerUsageLog.macLoggingCheckInterval + ServerUsageLog.staleRunInterval
                : ServerUsageLog.staleRunInterval
            if now.timeIntervalSince(lastRunAt) > staleInterval {
                parts = ["Logger hasn’t run since \(time(lastRunAt))"]
                isError = true
            } else if macIsLogging {
                parts = [
                    "Checking \(ServerUsageLog.describe(ServerUsageLog.macLoggingCheckInterval)) while this Mac reads usage · last check \(time(lastRunAt))"
                ]
            } else {
                parts = [
                    "Logging \(ServerUsageLog.describe(ServerUsageLog.checkInterval(for: provider))) · last check \(time(lastRunAt))"
                ]
            }
        } else {
            parts = ["Logger hasn’t run yet"]
        }
        if export.otherAccountEntryCount > 0 {
            parts.append("Skipped readings from a different account than this Mac.")
            isError = true
        }
        self.init(text: parts.joined(separator: ". "), isError: isError)
    }
}

private struct StoredState: Codable {
    let snapshot: UsageSnapshot?
    let samples: [UsageSample]
    let previousStatus: PaceStatus?
}
