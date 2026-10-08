import Foundation
import Observation

/// Owns the active sharing lifetime. Every await is followed by a generation check.
///
/// A sample leaves only after its five-minute bucket (`SharedSample.observedAt`) has closed, plus a
/// random delay that is drawn once per bucket, so the upload time says nothing more about when the
/// turn finished than the bucket does. Samples wait in the memory queue until then.
@MainActor @Observable
public final class SharingSession {
    /// The length of an observation bucket (contract "Privacy").
    static let bucketSeconds: TimeInterval = 300
    /// The longest random delay after a bucket closes.
    nonisolated static let maximumJitterSeconds: TimeInterval = 60
    /// The community board is fetched, and an upload attempted, at most this often.
    static let refreshInterval: TimeInterval = 30
    private static let maximumBatch = 50

    public private(set) var isEnabled = false
    public private(set) var board: GlobalBoard?
    public private(set) var status = "Local only"
    public private(set) var pendingCount = 0
    public private(set) var requiresUpdate = false
    @ObservationIgnored private let identity: any SharingIdentity
    @ObservationIgnored private let transport: any SharingTransport
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private var privateKey: Data?
    @ObservationIgnored private var consentStartedAt: Date?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var lastBoardRefresh: Date?
    @ObservationIgnored private var lastUploadAttempt: Date?
    @ObservationIgnored private var isRefreshing = false
    /// The random delay of each bucket, by the bucket's start; kept for as long as the queue keeps samples.
    @ObservationIgnored private var bucketJitter: [Date: TimeInterval] = [:]
    @ObservationIgnored private let jitterSource: @Sendable () -> TimeInterval
    private struct Pending { let localID: String; let sample: SharedSample; let completedAt: Date; let uploadableAt: Date }

    /// `jitter` draws a delay in seconds (0 up to `maximumJitterSeconds`); the default is
    /// `secureRandomJitter`.
    public init(
        identity: any SharingIdentity,
        transport: any SharingTransport = URLSessionSharingTransport(),
        baseURL: URL = URL(string: "https://tokrate.dev/api/public/v1")!,
        jitter: @escaping @Sendable () -> TimeInterval = SharingSession.secureRandomJitter
    ) {
        self.identity = identity; self.transport = transport; self.baseURL = baseURL; self.jitterSource = jitter
    }

    public func enable(now: Date = .now, startPolling: Bool = true) {
        guard !isEnabled, !requiresUpdate else { return }
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
                    guard let delay = self?.secondsUntilNextRefresh() else { return }
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }

    public func disable() {
        isEnabled = false
        generation = UUID()
        loopTask?.cancel(); loopTask = nil
        queue.removeAll(); seen.removeAll(); pendingCount = 0
        board = nil; privateKey = nil; consentStartedAt = nil; lastBoardRefresh = nil; lastUploadAttempt = nil
        bucketJitter.removeAll()
        isRefreshing = false
        status = "Local only"
    }

    public func enqueue(_ metrics: [TurnMetric], now: Date = .now) {
        guard isEnabled, let consentStartedAt else { return }
        prune(now: now)
        for metric in metrics where metric.completedAt >= consentStartedAt && metric.completedAt <= now && !seen.contains(metric.id) {
            guard let sample = SharedSample(metric) else { continue }
            seen.insert(metric.id)
            queue.append(Pending(localID: metric.id, sample: sample, completedAt: metric.completedAt, uploadableAt: uploadableAt(of: sample)))
        }
        if queue.count > 1000 { queue = Array(queue.suffix(1000)) }
        // The monitor/history also deduplicates. Bound this session's defense against repeated records.
        if seen.count > 50_000 { seen = Set(queue.map(\.localID)) }
        pendingCount = queue.count
    }

    /// Fetches the community board (at most every `refreshInterval`) and uploads the samples whose
    /// bucket has closed (one batch, at most every `refreshInterval`). The board does not depend on
    /// whether anything was uploaded.
    public func refresh(now: Date = .now) async {
        guard isEnabled, !isRefreshing, let privateKey else { return }
        prune(now: now)
        let boardDue = lastBoardRefresh.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        let batch = uploadBatch(now: now)
        guard boardDue || !batch.isEmpty else { return }
        let currentGeneration = generation
        isRefreshing = true
        defer { if generation == currentGeneration { isRefreshing = false } }
        if boardDue { lastBoardRefresh = now }
        if !batch.isEmpty {
            lastUploadAttempt = now
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
                } else if code == 426 {
                    stopForRequiredUpdate()
                    return
                } else { status = "Upload unavailable. Retrying while sharing is on." }
            } catch {
                guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
                status = "Offline. Retrying while sharing is on."
            }
        }
        pendingCount = queue.count
        guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
        guard boardDue else { return }
        do {
            let (data, code) = try await transport.send(URLRequest(url: baseURL.appendingPathComponent("board")))
            guard isEnabled, generation == currentGeneration, !Task.isCancelled else { return }
            if code == 426 {
                stopForRequiredUpdate()
                return
            }
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

    /// A delay drawn uniformly from 0 up to `maximumJitterSeconds` with the system's cryptographically
    /// secure random generator.
    public nonisolated static func secureRandomJitter() -> TimeInterval {
        var generator = SystemRandomNumberGenerator()
        return TimeInterval.random(in: 0..<maximumJitterSeconds, using: &generator)
    }

    /// How long the loop sleeps after a refresh: until the board is due again or the earliest queued
    /// sample may leave, whichever comes first. Never less than a second, so a pending retry cannot spin.
    func secondsUntilNextRefresh(now: Date = .now) -> TimeInterval {
        var due = lastBoardRefresh.map { $0.addingTimeInterval(Self.refreshInterval) } ?? now
        if let first = queue.map(\.uploadableAt).min() {
            let retry = lastUploadAttempt.map { $0.addingTimeInterval(Self.refreshInterval) } ?? first
            due = min(due, max(first, retry))
        }
        return max(1, due.timeIntervalSince(now))
    }

    /// The samples that may leave now: their bucket has closed and the bucket's delay has passed, and
    /// no attempt was made within the last `refreshInterval`.
    private func uploadBatch(now: Date) -> [Pending] {
        if let lastUploadAttempt, now >= lastUploadAttempt, now.timeIntervalSince(lastUploadAttempt) < Self.refreshInterval { return [] }
        return Array(queue.lazy.filter { $0.uploadableAt <= now }.prefix(Self.maximumBatch))
    }

    /// The end of the sample's bucket plus the bucket's random delay, drawn the first time the bucket is seen.
    private func uploadableAt(of sample: SharedSample) -> Date {
        let jitter: TimeInterval
        if let known = bucketJitter[sample.observedAt] {
            jitter = known
        } else {
            jitter = min(max(0, jitterSource()), Self.maximumJitterSeconds)
            bucketJitter[sample.observedAt] = jitter
        }
        return sample.observedAt.addingTimeInterval(Self.bucketSeconds + jitter)
    }

    private func stopForRequiredUpdate() {
        requiresUpdate = true
        isEnabled = false
        generation = UUID()
        loopTask?.cancel(); loopTask = nil
        queue.removeAll(); seen.removeAll(); pendingCount = 0
        board = nil; privateKey = nil; consentStartedAt = nil; lastBoardRefresh = nil; lastUploadAttempt = nil
        bucketJitter.removeAll()
        isRefreshing = false
        status = "This Tokrate version cannot share. Check for Updates."
    }

    private func prune(now: Date) {
        queue.removeAll { now.timeIntervalSince($0.sample.observedAt) > 86_400 }
        bucketJitter = bucketJitter.filter { now.timeIntervalSince($0.key) <= 86_400 }
        pendingCount = queue.count
    }
}
