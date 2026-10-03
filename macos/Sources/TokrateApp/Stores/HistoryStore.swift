import Foundation
import Observation
import TokrateCore

@MainActor
@Observable
final class HistoryStore {
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

    @ObservationIgnored private let persistenceURL: URL
    @ObservationIgnored private var monitor: CodexSessionMonitor?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var selectedFolder: URL
    @ObservationIgnored private var securityScopedFolder: URL?

    var records: [TurnMetric] { history.records }
    var menuBarTitle: String {
        guard isMonitoring, let latest = history.records.first else { return "— t/s" }
        let age = Date.now.timeIntervalSince(latest.completedAt)
        guard age >= 0, age <= 900, latest.turnThroughputTPS.isFinite, latest.turnThroughputTPS >= 0 else { return "— t/s" }
        return String(format: "%.1f t/s", latest.turnThroughputTPS)
    }
    var folderDescription: String { hasCustomFolder ? "Custom folder" : "Codex sessions" }

    init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tokrate", isDirectory: true)
        persistenceURL = supportDirectory.appendingPathComponent("history-v1.json")
        selectedFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

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
        isMonitoring = true
        saveHistory()
        guard let monitor else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let newRecords = try await monitor.poll()
                    guard let self else { return }
                    guard !Task.isCancelled, self.isMonitoring else { return }
                    let existing = Set(self.history.records.map(\.id))
                    self.sharing.enqueue(newRecords.filter { !existing.contains($0.id) })
                    self.history.prune()
                    for record in newRecords { self.history.upsert(record) }
                    if !newRecords.isEmpty { self.saveHistory() }
                    if newRecords.isEmpty { self.errorMessage = nil }
                } catch {
                    self?.errorMessage = "Could not read this folder. Check folder access and try again."
                    self?.stopMonitoring()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
        monitor = nil
        isMonitoring = false
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
}
