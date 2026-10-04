import Foundation
import Observation
import TokrateCore

@MainActor
@Observable
final class HistoryStore {
    private static let selectionDefaultsKey = "dashboardModelSelection"
    private static let clientFilterDefaultsKey = "dashboardClientFilter"
    private static let providerFilterDefaultsKey = "dashboardProviderFilter"
    private struct PersistedHistory: Codable {
        let schemaVersion: Int
        let records: [TurnMetric]
    }

    let sharingPreferences = SharingPreferences(session: SharingSession(identity: KeychainIdentity()))
    var sharing: SharingSession { sharingPreferences.session }
    private(set) var history: MetricHistory
    private(set) var isMonitoring = false
    private(set) var errorMessage: String?
    private(set) var hasCustomFolder = false
    private(set) var sourceStatus = "Waiting for session folders"
    var dashboardSelection: DashboardSelection {
        didSet { UserDefaults.standard.set(dashboardSelection.persistenceValue, forKey: Self.selectionDefaultsKey) }
    }
    var clientFilter: String? {
        didSet { Self.persistFilter(clientFilter, key: Self.clientFilterDefaultsKey) }
    }
    var providerFilter: String? {
        didSet { Self.persistFilter(providerFilter, key: Self.providerFilterDefaultsKey) }
    }

    @ObservationIgnored private let persistenceURL: URL
    @ObservationIgnored private var monitor: CodexSessionMonitor?
    @ObservationIgnored private var claudeMonitor: ClaudeSessionMonitor?
    @ObservationIgnored private var grokMonitor: GrokSessionMonitor?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var selectedFolder: URL
    @ObservationIgnored private let claudeProjectsFolder: URL
    @ObservationIgnored private let grokSessionsFolder: URL
    @ObservationIgnored private var securityScopedFolder: URL?

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
    var latestCohort: ModelCohort? {
        filteredRecords.max { $0.completedAt < $1.completedAt }.map(ModelCohort.init)
    }
    var menuBarTitle: String {
        guard isMonitoring else { return "— t/s" }
        if dashboardSelection.isAllModels { return "Compare" }
        let selectedCohort: ModelCohort?
        switch dashboardSelection {
        case .latest: selectedCohort = latestCohort
        case .cohort(let cohort): selectedCohort = cohort
        case .all: selectedCohort = nil
        }
        guard let selectedCohort,
              let latest = filteredRecords.first(where: { ModelCohort($0) == selectedCohort && $0.outputTokens >= 20 && $0.turnThroughputTPS.isFinite && $0.turnThroughputTPS >= 0 }) else {
            return "— t/s"
        }
        let age = Date.now.timeIntervalSince(latest.completedAt)
        guard age >= 0, age <= 900, latest.turnThroughputTPS.isFinite, latest.turnThroughputTPS >= 0 else { return "— t/s" }
        return String(format: "%.1f t/s", latest.turnThroughputTPS)
    }
    var folderDescription: String { sourceStatus }

    init() {
        dashboardSelection = DashboardSelection.restored(from: UserDefaults.standard.string(forKey: Self.selectionDefaultsKey))
        clientFilter = UserDefaults.standard.string(forKey: Self.clientFilterDefaultsKey)
        providerFilter = UserDefaults.standard.string(forKey: Self.providerFilterDefaultsKey)
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tokrate", isDirectory: true)
        persistenceURL = supportDirectory.appendingPathComponent("history-v1.json")
        selectedFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let claudeConfig = Self.configuredDirectory(
            override: environment["CLAUDE_CONFIG_DIR"],
            fallback: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        )
        claudeProjectsFolder = claudeConfig.appendingPathComponent("projects", isDirectory: true)
        let grokHome = Self.configuredDirectory(
            override: environment["GROK_HOME"],
            fallback: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
        )
        grokSessionsFolder = grokHome.appendingPathComponent("sessions", isDirectory: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: persistenceURL),
           let persisted = try? decoder.decode(PersistedHistory.self, from: data),
           persisted.schemaVersion == 1 {
            history = MetricHistory(records: persisted.records)
        } else {
            history = MetricHistory()
        }
    }

    func startAutomatically() {
        let launchedAt = Date.now
        sharingPreferences.activate(now: launchedAt)
        startMonitoring()
    }

    func selectFolder(_ url: URL) {
        releaseSelectedFolderAccess()
        let didStartAccess = url.startAccessingSecurityScopedResource()
        selectedFolder = url
        securityScopedFolder = didStartAccess ? url : nil
        hasCustomFolder = true
        errorMessage = nil
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        errorMessage = nil
        monitor = CodexSessionMonitor(root: selectedFolder)
        claudeMonitor = ClaudeSessionMonitor(root: claudeProjectsFolder)
        grokMonitor = GrokSessionMonitor(root: grokSessionsFolder)
        isMonitoring = true
        updateSourceStatus(claude: nil, grok: nil)
        saveHistory()
        let codexFolder = selectedFolder
        guard let monitor, let claudeMonitor, let grokMonitor else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                var newRecords: [TurnMetric] = []
                var failures: [String] = []
                if FileManager.default.fileExists(atPath: codexFolder.path) {
                    do {
                        newRecords += try await monitor.poll()
                    } catch {
                        failures.append("Codex sessions")
                    }
                }
                do {
                    newRecords += try await claudeMonitor.poll()
                } catch {
                    failures.append("Claude Code sessions")
                }
                do {
                    newRecords += try await grokMonitor.poll()
                } catch {
                    failures.append("Grok Build sessions")
                }
                guard let self else { return }
                guard !Task.isCancelled, self.isMonitoring else { return }
                let claudeStatus = await claudeMonitor.status()
                let grokStatus = await grokMonitor.status()
                self.updateSourceStatus(claude: claudeStatus, grok: grokStatus)
                self.errorMessage = failures.isEmpty ? nil : "Could not read \(failures.joined(separator: ", ")). Check folder access and try again."
                let existing = Set(self.history.records.map(\.id))
                self.sharing.enqueue(newRecords.filter { !existing.contains($0.id) })
                self.history.prune()
                for record in newRecords { self.history.upsert(record) }
                if !newRecords.isEmpty { self.saveHistory() }
                if newRecords.isEmpty, failures.isEmpty {
                    self.errorMessage = nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        monitor = nil
        claudeMonitor = nil
        grokMonitor = nil
        isMonitoring = false
        updateSourceStatus(claude: nil, grok: nil)
    }

    private func saveHistory() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let envelope = PersistedHistory(schemaVersion: 1, records: history.records)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            errorMessage = "Local history could not be saved."
        }
    }

    private func releaseSelectedFolderAccess() {
        securityScopedFolder?.stopAccessingSecurityScopedResource()
        securityScopedFolder = nil
    }

    private func updateSourceStatus(
        claude: (rootAvailable: Bool, files: Int)?,
        grok: (rootAvailable: Bool, sessions: Int)?
    ) {
        let codexAvailable = FileManager.default.fileExists(atPath: selectedFolder.path)
        let codex = hasCustomFolder ? "Custom Codex folder" : "Codex sessions"
        let claudeText = claude.map { $0.rootAvailable ? "Claude Code \($0.files) files" : "Claude Code folder not found" }
            ?? (FileManager.default.fileExists(atPath: claudeProjectsFolder.path) ? "Claude Code available" : "Claude Code folder not found")
        let grokText = grok.map { $0.rootAvailable ? "Grok Build \($0.sessions) sessions" : "Grok Build folder not found" }
            ?? (FileManager.default.fileExists(atPath: grokSessionsFolder.path) ? "Grok Build available" : "Grok Build folder not found")
        sourceStatus = "\(codex) \(codexAvailable ? "available" : "folder not found") · \(claudeText) · \(grokText)"
    }

    private static func configuredDirectory(override: String?, fallback: URL) -> URL {
        guard let override, !override.isEmpty else { return fallback }
        let url = URL(fileURLWithPath: override, isDirectory: true)
        return url.standardizedFileURL
    }

    private static func persistFilter(_ value: String?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
