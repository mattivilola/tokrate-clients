import Foundation
import Observation
import TokrateCore

/// One supported coding tool and whether its session folder was found.
struct SourceStatus: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case found
        case notFound
    }

    let client: String
    let availability: Availability
    /// Human-readable detail such as "12 session files"; nil when nothing more is known.
    let detail: String?
    /// The folder Tokrate reads, with the home directory abbreviated.
    let path: String

    var id: String { client }
    var title: String { SourceFolderKind(rawValue: client)?.title ?? ModelCohort.clientTitle(client) }
    var isFound: Bool { availability == .found }
}

/// The coding tools whose session folder the user can choose. Finder-launched apps do not inherit
/// shell variables such as `CLAUDE_CONFIG_DIR` or `GROK_HOME`, so each folder needs an in-app override.
/// The raw value is the stable client identifier.
enum SourceFolderKind: String, CaseIterable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case grokBuild = "grok-build"
    case antigravity
    case openCode = "opencode"
    case kimiCode = "kimi-code"
    /// The Kimi desktop app's embedded Kimi Code home: a second folder of the same client.
    case kimiDesktop = "kimi-desktop"

    var title: String {
        switch self {
        case .kimiDesktop: "Kimi desktop"
        default: ModelCohort.clientTitle(rawValue)
        }
    }

    /// What the chosen folder holds, as it appears in help text.
    var folderNoun: String {
        switch self {
        case .codex: "session folder"
        case .claudeCode: "projects folder"
        case .grokBuild: "sessions folder"
        case .antigravity, .openCode: "data folder"
        case .kimiCode, .kimiDesktop: "home folder"
        }
    }

    fileprivate var pathDefaultsKey: String { "sourceFolderPath.\(rawValue)" }
    fileprivate var bookmarkDefaultsKey: String { "sourceFolderBookmark.\(rawValue)" }
}

@MainActor
@Observable
final class HistoryStore {
    private static let selectionDefaultsKey = "dashboardModelSelection"
    private static let clientFilterDefaultsKey = "dashboardClientFilter"
    private static let providerFilterDefaultsKey = "dashboardProviderFilter"
    /// Polls never come closer than this, so a busy writer costs at most one poll per interval.
    nonisolated static let minimumPollSpacing: TimeInterval = 2
    /// The longest the app sleeps with nothing pending. A poll also ages the live readout and moves
    /// Auto model selection (`refreshLiveReadout`), which must not stall while the folders are quiet.
    nonisolated static let idlePollInterval: TimeInterval = 30
    /// `checkpoints` ride in the same file so that records and the files they were read from are written
    /// atomically together. A file without them (older builds, or a history that failed to load) is
    /// simply replayed in full; builds that do not know the field ignore it.
    private struct PersistedHistory: Codable {
        let schemaVersion: Int
        let records: [TurnMetric]
        let checkpoints: SourceCheckpoints?
    }

    let sharingPreferences: SharingPreferences
    var sharing: SharingSession { sharingPreferences.session }
    private(set) var history: MetricHistory
    private(set) var isMonitoring = false
    private(set) var errorMessage: String?
    /// Folders the user chose, by tool. Absent tools read their default (or environment) folder.
    private(set) var customFolders: [SourceFolderKind: URL] = [:]
    private(set) var sourceStatus = "Waiting for session folders"
    private(set) var sourceStatuses: [SourceStatus] = []
    var dashboardSelection: DashboardSelection {
        didSet {
            defaults.set(dashboardSelection.persistenceValue, forKey: Self.selectionDefaultsKey)
            refreshLiveReadout()
        }
    }
    var clientFilter: String? {
        didSet {
            Self.persistFilter(clientFilter, key: Self.clientFilterDefaultsKey, defaults: defaults)
            refreshLiveReadout()
        }
    }
    var providerFilter: String? {
        didSet {
            Self.persistFilter(providerFilter, key: Self.providerFilterDefaultsKey, defaults: defaults)
            refreshLiveReadout()
        }
    }
    /// The model Auto mode follows, chosen from the live response stream; nil when no qualifying
    /// response is recent.
    private(set) var activeModel: ResponseGroupKey?
    /// Live response speed of the selected model: the median of its latest responses in the last ten
    /// minutes. In-memory only.
    private(set) var liveSpeed: LiveSpeed?
    /// What the menu-bar item shows.
    private(set) var menuBarReadout = MenuBarReadout.unavailable
    @ObservationIgnored private var liveResponses = LiveResponseBuffer()
    /// The session files already read to their end, as the monitors last reported them. The next launch
    /// skips what it still matches (see `SourceFileCheckpoint`).
    @ObservationIgnored private(set) var checkpoints = SourceCheckpoints()
    /// The files `checkpoints` held when the history was last written.
    @ObservationIgnored private var savedCheckpointPaths: Set<String> = []
    /// Spaces out the history writes while records keep arriving.
    @ObservationIgnored private var saveThrottle = HistorySaveThrottle()
    @ObservationIgnored private var selector = ActiveModelSelector()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistenceURL: URL
    @ObservationIgnored private var monitor: CodexSessionMonitor?
    @ObservationIgnored private var claudeMonitor: ClaudeSessionMonitor?
    @ObservationIgnored private var grokMonitor: GrokSessionMonitor?
    @ObservationIgnored private var antigravityMonitor: AntigravityConversationMonitor?
    @ObservationIgnored private var openCodeMonitor: OpenCodeMonitor?
    @ObservationIgnored private var kimiCodeMonitor: KimiSessionMonitor?
    @ObservationIgnored private var kimiDesktopMonitor: KimiSessionMonitor?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    /// Keeps the seven-day retention while monitoring is paused, when no poll runs.
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private let pausedRetentionInterval: TimeInterval
    /// One watcher per existing source folder; a change wakes the polling task early.
    @ObservationIgnored private var watchers: [SourceFolderKind: SessionFolderWatcher] = [:]
    @ObservationIgnored private var waker: PollWaker?
    @ObservationIgnored private let defaultFolders: [SourceFolderKind: URL]
    @ObservationIgnored private var securityScopedFolders: [SourceFolderKind: URL] = [:]

    /// The largest history file that is loaded (the Windows/Linux client's bound; 50,000 records are far
    /// below it). A larger file, or one that is not a regular file, is read like a corrupt one: as no history.
    static let maximumHistoryBytes = 64 * 1_048_576

    var records: [TurnMetric] { history.records }
    var availableClients: [String] {
        Array(Set(history.records.map(\.client))).sorted()
    }
    var availableProviders: [String] {
        Array(Set(history.records.map { $0.provider ?? "unknown" })).sorted()
    }
    var filteredRecords: [TurnMetric] {
        history.records.filter { metric in
            (clientFilter == nil || metric.client == clientFilter)
                && (providerFilter == nil || (metric.provider ?? "unknown") == providerFilter)
        }
    }
    var availableCohorts: [ModelCohort] {
        let latestByCohort = Dictionary(grouping: filteredRecords, by: ModelCohort.init)
        return latestByCohort
            .map { cohort, metrics in (cohort, metrics.map(\.completedAt).max() ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
    /// The cohort an Auto selection currently resolves to, or the pinned cohort.
    var resolvedCohort: ModelCohort? {
        switch dashboardSelection {
        case .auto, .autoTool:
            AutoSelection.resolve(records: filteredRecords, activeModel: activeModel, client: dashboardSelection.autoClient)
        case .cohort(let cohort): cohort
        case .all: nil
        }
    }
    var folderDescription: String { sourceStatus }

    /// The defaults read the user's real preferences, history and session folders. Every parameter
    /// is a seam for tests and offscreen previews, which supply synthetic data and empty folders.
    init(
        persistenceURL: URL? = nil,
        codexFolder: URL? = nil,
        claudeProjectsFolder: URL? = nil,
        grokSessionsFolder: URL? = nil,
        antigravityDataFolder: URL? = nil,
        openCodeDataFolder: URL? = nil,
        kimiCodeFolder: URL? = nil,
        kimiDesktopFolder: URL? = nil,
        sharingPreferences: SharingPreferences? = nil,
        defaults: UserDefaults = .standard,
        initialRecords: [TurnMetric]? = nil,
        pausedRetentionInterval: TimeInterval = 3_600
    ) {
        self.defaults = defaults
        self.pausedRetentionInterval = pausedRetentionInterval
        self.sharingPreferences = sharingPreferences
            ?? SharingPreferences(session: SharingSession(identity: KeychainIdentity()))
        dashboardSelection = DashboardSelection.restored(from: defaults.string(forKey: Self.selectionDefaultsKey))
        clientFilter = defaults.string(forKey: Self.clientFilterDefaultsKey)
        providerFilter = defaults.string(forKey: Self.providerFilterDefaultsKey)
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tokrate", isDirectory: true)
        self.persistenceURL = persistenceURL ?? supportDirectory.appendingPathComponent("history-v1.json")
        let sourceDefaults = SourceFolders.defaults()
        defaultFolders = [
            .codex: codexFolder ?? sourceDefaults.codex,
            .claudeCode: claudeProjectsFolder ?? sourceDefaults.claudeCode,
            .grokBuild: grokSessionsFolder ?? sourceDefaults.grokBuild,
            .antigravity: antigravityDataFolder ?? sourceDefaults.antigravity,
            .openCode: openCodeDataFolder ?? sourceDefaults.openCode,
            .kimiCode: kimiCodeFolder ?? sourceDefaults.kimiCode,
            .kimiDesktop: kimiDesktopFolder ?? sourceDefaults.kimiDesktop
        ]

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let initialRecords {
            history = MetricHistory(records: initialRecords)
        } else if let data = try? RegularFile.read(self.persistenceURL, maximumBytes: Self.maximumHistoryBytes),
           let persisted = try? decoder.decode(PersistedHistory.self, from: data),
           persisted.schemaVersion == 1 {
            history = MetricHistory(records: persisted.records)
            checkpoints = persisted.checkpoints?.retained() ?? SourceCheckpoints()
            savedCheckpointPaths = checkpoints.pathDigests
        } else {
            history = MetricHistory()
        }
        for kind in SourceFolderKind.allCases {
            guard let restored = Self.restoredFolder(for: kind, defaults: defaults) else { continue }
            customFolders[kind] = restored.url
            if restored.hasScopedAccess { securityScopedFolders[kind] = restored.url }
        }
        updateSourceStatus(claude: nil, grok: nil)
    }

    func startAutomatically() {
        let launchedAt = Date.now
        sharingPreferences.activate(now: launchedAt)
        startMonitoring()
    }

    /// The folder a tool is read from: the user's choice, else the default or environment folder.
    func folder(for kind: SourceFolderKind) -> URL {
        customFolders[kind] ?? defaultFolders[kind]!
    }

    func hasCustomFolder(for kind: SourceFolderKind) -> Bool { customFolders[kind] != nil }

    /// Folders can only change while monitoring is paused, because monitors are created from them
    /// when monitoring starts. The choice is persisted so it survives relaunch.
    func selectFolder(_ url: URL, for kind: SourceFolderKind) {
        guard !isMonitoring else { return }
        releaseFolderAccess(for: kind)
        if url.startAccessingSecurityScopedResource() { securityScopedFolders[kind] = url }
        customFolders[kind] = url
        defaults.set(url.path, forKey: kind.pathDefaultsKey)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: kind.bookmarkDefaultsKey)
        } else {
            defaults.removeObject(forKey: kind.bookmarkDefaultsKey)
        }
        errorMessage = nil
        updateSourceStatus(claude: nil, grok: nil)
    }

    /// Returns a tool to its default (or environment-variable) folder.
    func resetFolder(for kind: SourceFolderKind) {
        guard !isMonitoring, customFolders[kind] != nil else { return }
        releaseFolderAccess(for: kind)
        customFolders[kind] = nil
        defaults.removeObject(forKey: kind.pathDefaultsKey)
        defaults.removeObject(forKey: kind.bookmarkDefaultsKey)
        errorMessage = nil
        updateSourceStatus(claude: nil, grok: nil)
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        retentionTask?.cancel()
        retentionTask = nil
        errorMessage = nil
        // Only responses that complete from now on count as live; replayed history is not "now".
        let launchedAt = Date.now
        monitor = CodexSessionMonitor(root: folder(for: .codex), liveSince: launchedAt, checkpoints: checkpoints.codex)
        claudeMonitor = ClaudeSessionMonitor(
            root: folder(for: .claudeCode), liveSince: launchedAt,
            primaryCheckpoints: checkpoints.claudePrimary, subagentCheckpoints: checkpoints.claudeSubagents
        )
        grokMonitor = GrokSessionMonitor(root: folder(for: .grokBuild))
        antigravityMonitor = AntigravityConversationMonitor(root: folder(for: .antigravity), liveSince: launchedAt)
        openCodeMonitor = OpenCodeMonitor(root: folder(for: .openCode), liveSince: launchedAt)
        kimiCodeMonitor = KimiSessionMonitor(
            root: folder(for: .kimiCode), surface: .cli, liveSince: launchedAt,
            mainCheckpoints: checkpoints.kimiCodeMain, subagentCheckpoints: checkpoints.kimiCodeSubagents
        )
        kimiDesktopMonitor = KimiSessionMonitor(
            root: folder(for: .kimiDesktop), surface: .desktop, liveSince: launchedAt,
            mainCheckpoints: checkpoints.kimiDesktopMain, subagentCheckpoints: checkpoints.kimiDesktopSubagents
        )
        isMonitoring = true
        refreshLiveReadout()
        updateSourceStatus(claude: nil, grok: nil)
        saveHistory()
        // That write only creates the file: the first records of the replay must not wait out its interval.
        saveThrottle.reset()
        let codexFolder = folder(for: .codex)
        guard let monitor, let claudeMonitor, let grokMonitor, let antigravityMonitor, let openCodeMonitor,
              let kimiCodeMonitor, let kimiDesktopMonitor else { return }
        let waker = PollWaker()
        self.waker = waker
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                // Before the poll, so a file written once a watcher exists is either reported by it or
                // already visible to the poll.
                self?.syncWatchers()
                var newRecords: [TurnMetric] = []
                var newResponses: [LiveResponse] = []
                // Request outcomes go to the sharing session only: never into the history or the UI.
                var newOutcomes: [RequestOutcome] = []
                var failures: [String] = []
                if FileManager.default.fileExists(atPath: codexFolder.path) {
                    do {
                        let update = try await monitor.poll()
                        newRecords += update.metrics
                        newResponses += update.responses
                        newOutcomes += update.outcomes
                    } catch {
                        failures.append("Codex sessions")
                    }
                }
                do {
                    let update = try await claudeMonitor.poll()
                    newRecords += update.metrics
                    newResponses += update.responses
                    newOutcomes += update.outcomes
                } catch {
                    failures.append("Claude Code sessions")
                }
                do {
                    let grokRecords = try await grokMonitor.poll()
                    newRecords += grokRecords
                    // Grok Build reports speed per turn only: each turn completed since launch is one live entry.
                    newResponses += grokRecords.compactMap { $0.completedAt >= launchedAt ? LiveResponse(turn: $0) : nil }
                } catch {
                    failures.append("Grok Build sessions")
                }
                let antigravityUpdate = await antigravityMonitor.poll()
                newRecords += antigravityUpdate.metrics
                newResponses += antigravityUpdate.responses
                let openCodeUpdate = await openCodeMonitor.poll()
                newRecords += openCodeUpdate.metrics
                newResponses += openCodeUpdate.responses
                newOutcomes += openCodeUpdate.outcomes
                do {
                    let update = try await kimiCodeMonitor.poll()
                    newRecords += update.metrics
                    newResponses += update.responses
                    newOutcomes += update.outcomes
                } catch {
                    failures.append("Kimi Code sessions")
                }
                do {
                    let update = try await kimiDesktopMonitor.poll()
                    newRecords += update.metrics
                    newResponses += update.responses
                    newOutcomes += update.outcomes
                } catch {
                    failures.append("Kimi desktop sessions")
                }
                guard let self else { return }
                guard !Task.isCancelled, self.isMonitoring else { return }
                let claudeStatus = await claudeMonitor.status()
                let grokStatus = await grokMonitor.status()
                let antigravityStatus = await antigravityMonitor.status()
                let openCodeStatus = await openCodeMonitor.status()
                let kimiCodeStatus = await kimiCodeMonitor.status()
                let kimiDesktopStatus = await kimiDesktopMonitor.status()
                self.updateSourceStatus(
                    claude: claudeStatus, grok: grokStatus, antigravity: antigravityStatus, openCode: openCodeStatus,
                    kimiCode: kimiCodeStatus, kimiDesktop: kimiDesktopStatus
                )
                self.errorMessage = failures.isEmpty ? nil : "Could not read \(failures.joined(separator: ", ")). Check folder access and try again."
                // A record is shared at most once, when it is both new to history and final: a primary
                // turn arrives first without its delegated total, and its settled re-emission shares it.
                let known = Dictionary(self.history.records.map { ($0.id, $0.isDelegationFinal) }, uniquingKeysWith: { first, _ in first })
                self.sharing.enqueue(newRecords.filter { $0.isDelegationFinal && known[$0.id] != true })
                self.sharing.enqueueOutcomes(newOutcomes)
                // Expired records leave the file within the seven days promised, also while no record arrives.
                let expiredRecords = self.history.prune()
                for record in newRecords { self.history.upsert(record) }
                // After the records are in the history, so a checkpoint never claims a file whose
                // records are not.
                await self.refreshCheckpoints(codex: monitor, claude: claudeMonitor, kimiCode: kimiCodeMonitor, kimiDesktop: kimiDesktopMonitor)
                self.recordLiveResponses(newResponses)
                if newRecords.isEmpty, failures.isEmpty {
                    self.errorMessage = nil
                }
                let polledAt = Date.now
                let monitorDeadlines = [
                    await monitor.nextPollDeadline(now: polledAt),
                    await claudeMonitor.nextPollDeadline(now: polledAt),
                    await grokMonitor.nextPollDeadline(now: polledAt),
                    await antigravityMonitor.nextPollDeadline(now: polledAt),
                    await openCodeMonitor.nextPollDeadline(now: polledAt),
                    await kimiCodeMonitor.nextPollDeadline(now: polledAt),
                    await kimiDesktopMonitor.nextPollDeadline(now: polledAt),
                    // A failed poll is retried at the normal cadence.
                    failures.isEmpty ? nil : polledAt
                ].compactMap { $0 }
                // A replay that just finished adds files to the checkpoints without a new record, so the
                // set is also written when the monitors go quiet; during a replay every poll would change it.
                let isIdle = monitorDeadlines.min().map { $0 > polledAt } ?? true
                if !newRecords.isEmpty || expiredRecords > 0 { self.saveThrottle.noteUnsavedChanges() }
                if self.saveThrottle.isDue(now: polledAt)
                    || (isIdle && self.checkpoints.pathDigests != self.savedCheckpointPaths) {
                    self.saveHistory(now: polledAt)
                }
                // A throttled write is not left to the next watcher event: it falls due at its own deadline.
                let deadline = (monitorDeadlines + [self.saveThrottle.dueAt(now: polledAt)].compactMap { $0 }).min()
                await Self.waitForNextPoll(lastPoll: polledAt, deadline: deadline, waker: waker)
            }
        }
    }

    /// How long to wait after the poll that ended at `lastPoll` before polling again: until `deadline`
    /// (the earliest time-based transition a monitor reported; nil when nothing is pending) but no
    /// sooner than the minimum spacing and no later than the idle interval.
    nonisolated static func pollDelay(now: Date, lastPoll: Date, deadline: Date?) -> TimeInterval {
        let idle = lastPoll.addingTimeInterval(idlePollInterval)
        let due = min(deadline ?? idle, idle)
        let earliest = lastPoll.addingTimeInterval(minimumPollSpacing)
        return max(0, max(due, earliest).timeIntervalSince(now))
    }

    /// Sleeps until the next poll is due, or until a watcher reports a change (observing the minimum
    /// spacing either way).
    private nonisolated static func waitForNextPoll(lastPoll: Date, deadline: Date?, waker: PollWaker) async {
        let delay = pollDelay(now: .now, lastPoll: lastPoll, deadline: deadline)
        guard await waker.wait(timeout: delay) else { return }
        try? await Task.sleep(for: .seconds(pollDelay(now: .now, lastPoll: lastPoll, deadline: .now)))
    }

    /// Watches every source folder that exists and drops the watcher of one that vanished, so a folder
    /// created or replaced after launch is picked up by the next poll cycle.
    private func syncWatchers() {
        guard let waker else { return }
        for kind in SourceFolderKind.allCases {
            let watched = watchedFolder(for: kind)
            guard FileManager.default.fileExists(atPath: watched.path) else {
                watchers.removeValue(forKey: kind)?.stop()
                continue
            }
            guard watchers[kind] == nil else { continue }
            let notify: @Sendable (SessionFolderChange) async -> Bool
            switch kind {
            case .codex:
                guard let monitor else { continue }
                notify = { await monitor.noteChanges($0) }
            case .claudeCode:
                guard let claudeMonitor else { continue }
                notify = { await claudeMonitor.noteChanges($0) }
            case .grokBuild:
                guard let grokMonitor else { continue }
                notify = { await grokMonitor.noteChanges($0) }
            case .antigravity:
                guard let antigravityMonitor else { continue }
                notify = { await antigravityMonitor.noteChanges($0) }
            case .openCode:
                guard let openCodeMonitor else { continue }
                notify = { await openCodeMonitor.noteChanges($0) }
            case .kimiCode:
                guard let kimiCodeMonitor else { continue }
                notify = { await kimiCodeMonitor.noteChanges($0) }
            case .kimiDesktop:
                guard let kimiDesktopMonitor else { continue }
                notify = { await kimiDesktopMonitor.noteChanges($0) }
            }
            // Only a change a monitor cares about wakes the poll.
            watchers[kind] = SessionFolderWatcher(root: watched) { change in
                Task { if await notify(change) { await waker.signal() } }
            }
        }
    }

    /// What a change watcher observes for a tool: its folder, except that a Kimi Code home is large and only
    /// its `sessions` folder holds logs.
    private func watchedFolder(for kind: SourceFolderKind) -> URL {
        switch kind {
        case .kimiCode, .kimiDesktop: KimiSessionMonitor.watchedFolder(home: folder(for: kind))
        default: folder(for: kind)
        }
    }

    /// Writes what the next launch needs when the app quits, so the files read since the last write are
    /// not replayed.
    func prepareForTermination() {
        if isMonitoring { saveHistory() }
    }

    private func refreshCheckpoints(
        codex: CodexSessionMonitor, claude: ClaudeSessionMonitor, kimiCode: KimiSessionMonitor, kimiDesktop: KimiSessionMonitor
    ) async {
        // Nil means "unknown, keep the previous set" (see the monitors' `checkpoints()`).
        if let fresh = await codex.checkpoints() { checkpoints.codex = fresh }
        if let fresh = await claude.checkpoints() {
            checkpoints.claudePrimary = fresh.primary
            checkpoints.claudeSubagents = fresh.subagents
        }
        if let fresh = await kimiCode.checkpoints() {
            checkpoints.kimiCodeMain = fresh.main
            checkpoints.kimiCodeSubagents = fresh.subagents
        }
        if let fresh = await kimiDesktop.checkpoints() {
            checkpoints.kimiDesktopMain = fresh.main
            checkpoints.kimiDesktopSubagents = fresh.subagents
        }
    }

    func stopMonitoring() {
        // Expired records leave the file now, not at the next start.
        if isMonitoring {
            history.prune()
            saveHistory()
        }
        pollingTask?.cancel()
        pollingTask = nil
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        waker = nil
        monitor = nil
        claudeMonitor = nil
        grokMonitor = nil
        antigravityMonitor = nil
        openCodeMonitor = nil
        kimiCodeMonitor = nil
        kimiDesktopMonitor = nil
        isMonitoring = false
        refreshLiveReadout()
        updateSourceStatus(claude: nil, grok: nil)
        startPausedRetention()
    }

    /// While paused nothing polls, so records would outlive their seven days on disk: an idle timer
    /// prunes and saves, reading no source.
    private func startPausedRetention() {
        retentionTask?.cancel()
        let interval = pausedRetentionInterval
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                self?.pruneExpiredWhilePaused()
            }
        }
    }

    private func pruneExpiredWhilePaused(now: Date = .now) {
        guard !isMonitoring, history.prune(now: now) > 0 else { return }
        saveHistory(now: now)
    }

    /// Adds completed responses to the live buffer and re-evaluates the active model and readout.
    /// Called after every poll, once its turns are in the history, so the readout follows new turns
    /// and a model that has gone quiet also ages out of the live value.
    func recordLiveResponses(_ responses: [LiveResponse], now: Date = .now) {
        liveResponses.append(contentsOf: responses)
        refreshLiveReadout(now: now)
    }

    private func refreshLiveReadout(now: Date = .now) {
        let eligible = liveResponses.responses.filter { response in
            (clientFilter == nil || response.client == clientFilter)
                && (providerFilter == nil || (response.provider ?? "unknown") == providerFilter)
        }
        selector.clientRestriction = dashboardSelection.autoClient
        let active = selector.update(responses: eligible, now: now)
        let group: ResponseGroupKey? = switch dashboardSelection {
        case .auto, .autoTool: active
        case .cohort(let cohort): cohort.model == nil ? nil : ResponseGroupKey(cohort)
        case .all: nil
        }
        let speed = isMonitoring ? liveResponses.liveSpeed(for: group, now: now) : nil
        // The same reading as the popover gauge: live median, else the latest turn.
        let reading = isMonitoring && !dashboardSelection.isAllModels
            ? HeroSources(
                records: history.records, selection: dashboardSelection, activeModel: active,
                now: now, clientFilter: clientFilter, providerFilter: providerFilter
            ).reading(live: speed, liveGroup: speed == nil ? nil : group)
            : .empty
        let readout = MenuBarReadout.make(isMonitoring: isMonitoring, selection: dashboardSelection, reading: reading)
        // Assign only changes, so observers re-render when the readout actually moves.
        if active != activeModel { activeModel = active }
        if speed != liveSpeed { liveSpeed = speed }
        if readout != menuBarReadout { menuBarReadout = readout }
    }

    private func saveHistory(now: Date = .now) {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            checkpoints = checkpoints.retained()
            let envelope = PersistedHistory(schemaVersion: 1, records: history.records, checkpoints: checkpoints)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            try PrivateFile.write(data, to: persistenceURL)
            savedCheckpointPaths = checkpoints.pathDigests
            saveThrottle.didSave(at: now, succeeded: true)
        } catch {
            saveThrottle.didSave(at: now, succeeded: false)
            errorMessage = "Local history could not be saved."
        }
    }

    private func releaseFolderAccess(for kind: SourceFolderKind) {
        securityScopedFolders.removeValue(forKey: kind)?.stopAccessingSecurityScopedResource()
    }

    /// Resolves a persisted folder choice. The bookmark wins because it follows a moved or renamed
    /// folder; the stored path is the fallback and is refreshed from the bookmark.
    private static func restoredFolder(for kind: SourceFolderKind, defaults: UserDefaults) -> (url: URL, hasScopedAccess: Bool)? {
        guard let path = defaults.string(forKey: kind.pathDefaultsKey) else { return nil }
        if let bookmark = defaults.data(forKey: kind.bookmarkDefaultsKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let hasScopedAccess = url.startAccessingSecurityScopedResource()
                if isStale,
                   let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(fresh, forKey: kind.bookmarkDefaultsKey)
                }
                defaults.set(url.path, forKey: kind.pathDefaultsKey)
                return (url, hasScopedAccess)
            }
        }
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }

    private func updateSourceStatus(
        claude: (rootAvailable: Bool, files: Int)?,
        grok: (rootAvailable: Bool, sessions: Int)?,
        antigravity: (rootAvailable: Bool, conversations: Int)? = nil,
        openCode: (rootAvailable: Bool, sessions: Int)? = nil,
        kimiCode: (rootAvailable: Bool, files: Int)? = nil,
        kimiDesktop: (rootAvailable: Bool, files: Int)? = nil
    ) {
        let codexFolder = folder(for: .codex), claudeFolder = folder(for: .claudeCode), grokFolder = folder(for: .grokBuild)
        let antigravityFolder = folder(for: .antigravity)
        let antigravityOnDisk = AntigravityConversationMonitor.hasConversationFolder(root: antigravityFolder)
        let openCodeFolder = folder(for: .openCode)
        let openCodeOnDisk = OpenCodeMonitor.hasDatabase(root: openCodeFolder)
        let kimiCodeFolder = folder(for: .kimiCode), kimiDesktopFolder = folder(for: .kimiDesktop)
        let codexAvailable = FileManager.default.fileExists(atPath: codexFolder.path)
        let codex = hasCustomFolder(for: .codex) ? "Custom Codex folder" : "Codex sessions"
        let claudeText = claude.map { $0.rootAvailable ? "Claude Code \($0.files) files" : "Claude Code folder not found" }
            ?? (FileManager.default.fileExists(atPath: claudeFolder.path) ? "Claude Code available" : "Claude Code folder not found")
        let grokText = grok.map { $0.rootAvailable ? "Grok Build \($0.sessions) sessions" : "Grok Build folder not found" }
            ?? (FileManager.default.fileExists(atPath: grokFolder.path) ? "Grok Build available" : "Grok Build folder not found")
        let antigravityText = antigravity.map { $0.rootAvailable ? "Antigravity \($0.conversations) conversations" : "Antigravity folder not found" }
            ?? (antigravityOnDisk ? "Antigravity available" : "Antigravity folder not found")
        let openCodeText = openCode.map { $0.rootAvailable ? "OpenCode \($0.sessions) sessions" : "OpenCode folder not found" }
            ?? (openCodeOnDisk ? "OpenCode available" : "OpenCode folder not found")
        let kimiCodeText = kimiCode.map { $0.rootAvailable ? "Kimi Code \($0.files) files" : "Kimi Code folder not found" }
            ?? (FileManager.default.fileExists(atPath: kimiCodeFolder.path) ? "Kimi Code available" : "Kimi Code folder not found")
        let kimiDesktopText = kimiDesktop.map { $0.rootAvailable ? "Kimi desktop \($0.files) files" : "Kimi desktop folder not found" }
            ?? (FileManager.default.fileExists(atPath: kimiDesktopFolder.path) ? "Kimi desktop available" : "Kimi desktop folder not found")
        sourceStatus = "\(codex) \(codexAvailable ? "available" : "folder not found") · \(claudeText) · \(grokText) · \(antigravityText) · \(openCodeText) · \(kimiCodeText) · \(kimiDesktopText)"

        let claudeFound = claude?.rootAvailable ?? FileManager.default.fileExists(atPath: claudeFolder.path)
        let grokFound = grok?.rootAvailable ?? FileManager.default.fileExists(atPath: grokFolder.path)
        let antigravityFound = antigravity?.rootAvailable ?? antigravityOnDisk
        let openCodeFound = openCode?.rootAvailable ?? openCodeOnDisk
        let kimiCodeFound = kimiCode?.rootAvailable ?? FileManager.default.fileExists(atPath: kimiCodeFolder.path)
        let kimiDesktopFound = kimiDesktop?.rootAvailable ?? FileManager.default.fileExists(atPath: kimiDesktopFolder.path)
        sourceStatuses = [
            SourceStatus(
                client: TurnMetric.codexClient,
                availability: codexAvailable ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .codex), nil),
                path: Self.displayPath(codexFolder)
            ),
            SourceStatus(
                client: "claude-code",
                availability: claudeFound ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .claudeCode), claude.flatMap { $0.rootAvailable ? "\($0.files) session files" : nil }),
                path: Self.displayPath(claudeFolder)
            ),
            SourceStatus(
                client: "grok-build",
                availability: grokFound ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .grokBuild), grok.flatMap { $0.rootAvailable ? "\($0.sessions) sessions" : nil }),
                path: Self.displayPath(grokFolder)
            ),
            SourceStatus(
                client: "antigravity",
                availability: antigravityFound ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .antigravity), antigravity.flatMap { $0.rootAvailable ? "\($0.conversations) conversations" : nil }),
                path: Self.displayPath(antigravityFolder)
            ),
            SourceStatus(
                client: "opencode",
                availability: openCodeFound ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .openCode), openCode.flatMap { $0.rootAvailable ? "\($0.sessions) sessions" : nil }),
                path: Self.displayPath(openCodeFolder)
            ),
            SourceStatus(
                client: SourceFolderKind.kimiCode.rawValue,
                availability: kimiCodeFound ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .kimiCode), kimiCode.flatMap { $0.rootAvailable ? "\($0.files) session files" : nil }),
                path: Self.displayPath(kimiCodeFolder)
            ),
            SourceStatus(
                client: SourceFolderKind.kimiDesktop.rawValue,
                availability: kimiDesktopFound ? .found : .notFound,
                detail: Self.detail(custom: hasCustomFolder(for: .kimiDesktop), kimiDesktop.flatMap { $0.rootAvailable ? "\($0.files) session files" : nil }),
                path: Self.displayPath(kimiDesktopFolder)
            )
        ]
    }

    private static func detail(custom: Bool, _ count: String?) -> String? {
        let parts = [custom ? "Custom folder" : nil, count].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private static func persistFilter(_ value: String?, key: String, defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
