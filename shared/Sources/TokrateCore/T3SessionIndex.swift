import Foundation

/// In-memory provenance only: the SQL extracts native IDs and turn times, never thread titles,
/// messages, paths, token totals or complete JSON payloads. IDs never enter telemetry.
final class T3SessionIndex: @unchecked Sendable {
    struct Window: Sendable {
        let start: Date
        let end: Date
    }
    private let root: URL
    private let lock = NSLock()
    private var windows: [String: [Window]] = [:]
    private var signature: DatabaseFileSignature?
    private var lastRefresh = Date.distantPast
    private static let maximumRows = 20_000

    init(root: URL) { self.root = root }

    func refresh(now: Date = .now) {
        lock.lock(); defer { lock.unlock() }
        let url = root.appendingPathComponent("statev2.sqlite")
        guard let current = DatabaseFileSignature.of(url) else { windows = [:]; return }
        // Refresh active interval ends even when the database did not change.
        guard current != signature || now.timeIntervalSince(lastRefresh) >= 2 else { return }
        lastRefresh = now
        do {
            let db = try ReadOnlySQLiteDatabase(url: url)
            defer { db.close() }
            let rows: [(String, Window)] = try db.readTransaction {
                try db.query("""
                    SELECT json_extract(t.payload_json, '$.nativeThreadRef.nativeId'),
                           p.started_at, p.completed_at
                    FROM orchestration_v2_projection_provider_threads t
                    JOIN orchestration_v2_projection_provider_turns p ON p.provider_thread_id = t.provider_thread_id
                    WHERE json_extract(t.payload_json, '$.nativeThreadRef.driver') = 'claudeAgent'
                      AND json_extract(t.payload_json, '$.nativeThreadRef.strength') = 'strong'
                      AND p.started_at >= ?
                    ORDER BY p.started_at DESC LIMIT 20001
                    """, bindings: [.text(ISO8601DateFormatter().string(from: now.addingTimeInterval(-7 * 86_400)))]) { row in
                    guard let id = row.text(0), UUID(uuidString: id) != nil,
                          let startText = row.text(1), let start = TranscriptTimestamp.parse(startText),
                          start <= now.addingTimeInterval(2) else { return nil }
                    let end: Date
                    if row.isNull(2) {
                        guard now.timeIntervalSince(start) <= 3_600 else { return nil }
                        end = now
                    } else {
                        guard let text = row.text(2), let value = TranscriptTimestamp.parse(text) else { return nil }
                        end = value
                    }
                    guard end >= start, end.timeIntervalSince(start) <= 86_400, end <= now.addingTimeInterval(2) else { return nil }
                    return (id.lowercased(), Window(start: start, end: end))
                }
            }
            guard rows.count <= Self.maximumRows else { windows = [:]; return }
            windows = Dictionary(grouping: rows, by: { $0.0 }).mapValues { $0.map(\.1) }
            signature = current
        } catch {
            // Fail closed; unavailable/stale provenance cannot assign someone else's SDK work to T3.
            windows = [:]
        }
    }

    func contains(session: String?, at time: Date) -> Bool {
        guard let session else { return false }
        lock.lock(); defer { lock.unlock() }
        let matches = windows[session.lowercased(), default: []].filter {
            time >= $0.start.addingTimeInterval(-2) && time <= $0.end.addingTimeInterval(2)
        }
        return matches.count == 1
    }
}
