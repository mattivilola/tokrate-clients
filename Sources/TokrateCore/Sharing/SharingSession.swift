import Foundation
import Observation

/// Owns the network consent lifetime. Every await is followed by a generation check.
@MainActor @Observable
public final class SharingSession {
    public private(set) var isEnabled = false
    public private(set) var board: GlobalBoard?
    public private(set) var status = "Local only"
    public private(set) var pendingCount = 0
    @ObservationIgnored private let identity: any SharingIdentity
    @ObservationIgnored private let transport: any SharingTransport
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private var privateKey: Data?
    @ObservationIgnored private var consentStartedAt: Date?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var isRefreshing = false
    private struct Pending { let localID: String; let sample: SharedSample; let completedAt: Date }

    public init(identity: any SharingIdentity, transport: any SharingTransport = URLSessionSharingTransport(), baseURL: URL = URL(string: "https://tokrate.dev/api/public/v1")!) {
        self.identity = identity; self.transport = transport; self.baseURL = baseURL
    }

    public func enable(now: Date = .now, startPolling: Bool = true) {
        guard !isEnabled else { return }
        do { privateKey = try identity.loadOrCreate() }
        catch { status = "Sharing could not start. Check Keychain access and try again."; return }
        generation = UUID()
        consentStartedAt = now
        isEnabled = true
        status = "Sharing new turns"
        if startPolling {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
    }

    public func disable() {
        isEnabled = false
        generation = UUID()
        loopTask?.cancel(); loopTask = nil
        queue.removeAll(); seen.removeAll(); pendingCount = 0
        board = nil; privateKey = nil; consentStartedAt = nil; lastRefresh = nil
        isRefreshing = false
        status = "Local only"
    }

    public func enqueue(_ metrics: [TurnMetric], now: Date = .now) {
        guard isEnabled, let consentStartedAt else { return }
        prune(now: now)
        for metric in metrics where metric.completedAt >= consentStartedAt && metric.completedAt <= now && !seen.contains(metric.id) {
            guard let sample = SharedSample(metric) else { continue }
            seen.insert(metric.id)
            queue.append(Pending(localID: metric.id, sample: sample, completedAt: metric.completedAt))
        }
        if queue.count > 1000 { queue = Array(queue.suffix(1000)) }
        // The monitor/history also deduplicates. Bound this session's defense against repeated records.
        if seen.count > 50_000 { seen = Set(queue.map(\.localID)) }
        pendingCount = queue.count
    }

    public func refresh(now: Date = .now) async {
        guard isEnabled, !isRefreshing, let privateKey,
              lastRefresh.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        let currentGeneration = generation
        isRefreshing = true; lastRefresh = now
        defer { if generation == currentGeneration { isRefreshing = false } }
        prune(now: now)
        let batch = Array(queue.prefix(50))
        if !batch.isEmpty {
            do {
                let request = try SampleRequest.signed(samples: batch.map(\.sample), privateKey: privateKey, sentAt: now, baseURL: baseURL)
                guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
                let (_, code) = try await transport.send(request)
                guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
                if (200..<300).contains(code) {
                    let sent = Set(batch.map { $0.sample.sampleId })
                    queue.removeAll { sent.contains($0.sample.sampleId) }
                    status = "Sharing new turns"
                } else if code == 400 || code == 413 || code == 422 {
                    let rejected = Set(batch.map { $0.sample.sampleId })
                    queue.removeAll { rejected.contains($0.sample.sampleId) }
                    status = "Some samples were rejected. Local history is safe."
                } else { status = "Upload unavailable. Retrying while sharing is on." }
            } catch {
                guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
                status = "Offline. Retrying while sharing is on."
            }
        }
        pendingCount = queue.count
        guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
        do {
            let (data, code) = try await transport.send(URLRequest(url: baseURL.appendingPathComponent("board")))
            guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
            guard code == 200 else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode(GlobalBoard.self, from: data)
            guard decoded.schemaVersion == 1 else { throw URLError(.cannotParseResponse) }
            board = decoded
        } catch {
            guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
            board = nil
            status = "Global data unavailable. Local monitoring continues."
        }
    }
    private func prune(now: Date) {
        queue.removeAll { now.timeIntervalSince($0.sample.observedAt) > 86_400 }
        pendingCount = queue.count
    }
}
