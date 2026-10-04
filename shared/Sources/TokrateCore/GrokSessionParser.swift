import CoreFoundation
import CryptoKit
import Foundation

/// Folds completed primary work turns with the matching Grok usage ledger snapshot.
/// Subagent output remains part of the reported root work-turn total.
struct GrokSessionParser: JSONLMetricParser {
    private static let earlyTimestampTolerance: TimeInterval = 1
    private static let maximumUsageWriteDelay: TimeInterval = 60

    private struct TurnStart: Sendable {
        let number: Int
        let startedAt: Date
        let sessionID: String
    }

    private enum Frame: Sendable {
        case primary(Int)
        case subagent
        case ambiguous
    }

    private struct EndedTurn: Sendable {
        let start: TurnStart
        let endedAt: Date
        let outcome: String
    }

    private struct UsageTurn: Equatable, Sendable {
        let endedAt: Date
        let outputTokens: Int
        let reasoningTokens: Int?
        let model: String?
    }

    private var sourceIdentity: String
    private var sessionID: String?
    private var stack: [Frame] = []
    private var activeStart: TurnStart?
    private var seenPrimaryTurnNumbers: Set<Int> = []
    private var ambiguousTurnNumbers: Set<Int> = []
    private var endedTurns: [Int: EndedTurn] = [:]
    private var usageTurns: [Int: UsageTurn] = [:]
    private var emittedTurnNumbers: Set<Int> = []
    private var pendingEndedTurnNumbers: Set<Int> = []
    private var nextPrimaryStartAtByTurnNumber: [Int: Date] = [:]

    init(sourceIdentity: String) { self.sourceIdentity = sourceIdentity }

    mutating func reset(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
        sessionID = nil
        stack.removeAll(keepingCapacity: true)
        activeStart = nil
        seenPrimaryTurnNumbers.removeAll(keepingCapacity: true)
        ambiguousTurnNumbers.removeAll(keepingCapacity: true)
        endedTurns.removeAll(keepingCapacity: true)
        usageTurns.removeAll(keepingCapacity: true)
        emittedTurnNumbers.removeAll(keepingCapacity: true)
        pendingEndedTurnNumbers.removeAll(keepingCapacity: true)
        nextPrimaryStartAtByTurnNumber.removeAll(keepingCapacity: true)
    }

    mutating func consume(line: Data) -> TurnMetric? {
        guard line.count <= JSONLFileReader.maximumLineBytes,
              let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String
        else { return nil }
        if endedTurns.count > 8_192 {
            endedTurns.removeAll(keepingCapacity: true)
            seenPrimaryTurnNumbers.removeAll(keepingCapacity: true)
            ambiguousTurnNumbers.removeAll(keepingCapacity: true)
            emittedTurnNumbers.removeAll(keepingCapacity: true)
            pendingEndedTurnNumbers.removeAll(keepingCapacity: true)
            nextPrimaryStartAtByTurnNumber.removeAll(keepingCapacity: true)
        }

        if type == "turn_started" {
            consumeStart(event)
        } else if type == "turn_ended" {
            consumeEnd(event)
        }
        return nil
    }

    mutating func reconcile(snapshot: Data) -> [TurnMetric] {
        guard snapshot.count <= 262_144,
              let root = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any],
              let ledgerSessionID = safeIdentifier(root["sessionId"] as? String),
              let updatedAt = parseDate(root["updatedAt"]),
              let sessionID, ledgerSessionID == sessionID,
              let entries = root["turns"] as? [[String: Any]]
        else { return [] }

        var replacement: [Int: UsageTurn] = [:]
        var duplicateNumbers: Set<Int> = []
        for entry in entries {
            guard let number = nonnegativeInteger(entry["turnNumber"]),
                  let endedAt = parseDate(entry["endedAt"]),
                  let outputTokens = nonnegativeInteger(entry["outputTokens"]),
                  endedAt <= updatedAt.addingTimeInterval(1),
                  entry["usageIsIncomplete"] as? Bool != true,
                  validTurnCount(entry["turnCount"])
            else { continue }
            let model = soleModelUsage(entry["modelUsage"])
            let reasoningTokens = nonnegativeInteger(entry["reasoningTokens"]).flatMap { $0 <= outputTokens ? $0 : nil }
            let value = UsageTurn(endedAt: endedAt, outputTokens: outputTokens, reasoningTokens: reasoningTokens, model: model)
            if replacement[number] != nil {
                duplicateNumbers.insert(number)
            } else {
                replacement[number] = value
            }
        }
        for number in duplicateNumbers { replacement.removeValue(forKey: number) }

        // Usage JSON is a replacement snapshot, so never add its totals to an earlier read.
        for number in emittedTurnNumbers {
            if let old = usageTurns[number], let new = replacement[number], old != new {
                ambiguousTurnNumbers.insert(number)
            } else if usageTurns[number] != nil, replacement[number] == nil {
                ambiguousTurnNumbers.insert(number)
            }
        }
        usageTurns = replacement

        var records: [TurnMetric] = []
        for (number, eventTurn) in endedTurns where !emittedTurnNumbers.contains(number) {
            guard !ambiguousTurnNumbers.contains(number), eventTurn.outcome == "completed",
                  let usage = usageTurns[number],
                  usage.endedAt >= eventTurn.endedAt.addingTimeInterval(-Self.earlyTimestampTolerance),
                  usage.endedAt <= eventTurn.endedAt.addingTimeInterval(Self.maximumUsageWriteDelay),
                  nextPrimaryStartAtByTurnNumber[number].map({ usage.endedAt <= $0 }) ?? true,
                  eventTurn.start.sessionID == sessionID
            else { continue }
            let duration = eventTurn.endedAt.timeIntervalSince(eventTurn.start.startedAt)
            guard duration.isFinite, duration > 0 else { continue }
            let rate = Double(usage.outputTokens) / duration
            guard rate.isFinite, rate >= 0 else { continue }
            let digest = SHA256.hash(data: Data("\(sessionID)|\(number)".utf8))
            records.append(TurnMetric(
                id: digest.map { String(format: "%02x", $0) }.joined(),
                completedAt: eventTurn.endedAt,
                model: usage.model,
                outputTokens: usage.outputTokens,
                durationSeconds: duration,
                codexTTFTSeconds: nil,
                turnThroughputTPS: rate,
                streamingTPS: nil,
                client: "grok-build",
                clientVersion: nil,
                parserVersion: "grok-session-v1",
                metricVersion: "grok-observed-work-turn-v1",
                reasoningOutputTokens: usage.reasoningTokens,
                sourceKind: "primary",
                provider: "unknown"
            ))
            emittedTurnNumbers.insert(number)
        }
        return records
    }

    private mutating func consumeStart(_ event: [String: Any]) {
        guard event["schema_version"] as? String == "1.0",
              let relationship = event["session_relationship"] as? String,
              let id = safeIdentifier(event["session_id"] as? String),
              let number = nonnegativeInteger(event["turn_number"]),
              let timestamp = parseDate(event["ts"])
        else {
            invalidateActivePrimary()
            if !stack.isEmpty { stack.append(.ambiguous) }
            return
        }
        if let sessionID, sessionID != id {
            invalidateActivePrimary()
            stack.append(.ambiguous)
            return
        }
        sessionID = id

        if relationship == "subagent" {
            guard stack.count < 64 else {
                invalidateActivePrimary()
                stack.append(.ambiguous)
                return
            }
            stack.append(.subagent)
            return
        }
        guard relationship == "primary" else {
            invalidateActivePrimary()
            stack.append(.ambiguous)
            return
        }

        guard stack.isEmpty else {
            invalidateActivePrimary()
            stack.append(.ambiguous)
            return
        }
        for number in pendingEndedTurnNumbers {
            nextPrimaryStartAtByTurnNumber[number] = timestamp
        }
        pendingEndedTurnNumbers.removeAll(keepingCapacity: true)
        guard !seenPrimaryTurnNumbers.contains(number) else {
            ambiguousTurnNumbers.insert(number)
            stack = [.ambiguous]
            activeStart = nil
            return
        }
        seenPrimaryTurnNumbers.insert(number)
        let start = TurnStart(number: number, startedAt: timestamp, sessionID: id)
        activeStart = start
        stack = [.primary(number)]
    }

    private mutating func consumeEnd(_ event: [String: Any]) {
        guard let timestamp = parseDate(event["ts"]), let frame = stack.popLast() else { return }
        guard stack.isEmpty else { return }
        guard case .primary(let number) = frame, let start = activeStart, start.number == number else {
            activeStart = nil
            return
        }
        activeStart = nil
        if let rawID = event["session_id"] as? String,
           let id = safeIdentifier(rawID), id != start.sessionID {
            ambiguousTurnNumbers.insert(number)
            return
        }
        let outcome = event["outcome"] as? String ?? "unknown"
        guard ["completed", "cancelled", "error", "interrupted"].contains(outcome) else {
            ambiguousTurnNumbers.insert(number)
            return
        }
        if endedTurns[number] != nil {
            ambiguousTurnNumbers.insert(number)
            endedTurns.removeValue(forKey: number)
            pendingEndedTurnNumbers.remove(number)
            return
        }
        endedTurns[number] = EndedTurn(start: start, endedAt: timestamp, outcome: outcome)
        pendingEndedTurnNumbers.insert(number)
    }

    private mutating func invalidateActivePrimary() {
        if let activeStart { ambiguousTurnNumbers.insert(activeStart.number) }
        activeStart = nil
    }

    private func soleModelUsage(_ value: Any?) -> String? {
        guard let models = value as? [String: Any] else { return nil }
        let names = models.keys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard names.count == 1 else { return nil }
        let name = names[0]
        return safeIdentifier(name, maximum: 80)
    }

    private func validTurnCount(_ value: Any?) -> Bool {
        guard let value else { return true }
        return nonnegativeInteger(value) == 1
    }

    private func safeIdentifier(_ value: String?, maximum: Int = 120) -> String? {
        guard let value, value.count <= maximum,
              value.range(of: "^[a-zA-Z0-9._-]{1,\(maximum)}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double, double < Double(Int.max) else { return nil }
        return number.intValue
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public actor GrokSessionMonitor {
    private static let maximumFiles = 2_000
    private static let maximumPollBytes = 1_048_576
    private static let eventBatchBytes = 65_536
    private static let maximumUsageBytes = 262_144
    private static let snapshotStabilitySeconds: TimeInterval = 4

    private struct WatchedSession {
        var events: IncrementalJSONLMetricReader<GrokSessionParser>
        var eventsModifiedAt: Date
        var usageModifiedAt: Date?
        var usageData: Data?
        var stableSince: Date?
        var usageReadCheckedAt = Date.distantPast
    }

    private let root: URL
    private var sessions: [String: WatchedSession] = [:]
    private var lastDiscovery = Date.distantPast
    private var nextSessionIndex = 0
    private(set) var rootIsAvailable = false
    private(set) var watchedSessionCount = 0

    public init(root: URL) { self.root = root }

    public func poll(now: Date = .now) throws -> [TurnMetric] {
        if now.timeIntervalSince(lastDiscovery) >= 10 || sessions.isEmpty {
            try discoverSessions(now: now)
            lastDiscovery = now
        }
        guard rootIsAvailable, !sessions.isEmpty else { return [] }

        let keys = sessions.keys.sorted { left, right in
            let a = sessions[left]!.eventsModifiedAt, b = sessions[right]!.eventsModifiedAt
            return a == b ? left < right : a > b
        }
        guard !keys.isEmpty else { return [] }
        var budget = Self.maximumPollBytes
        var processed = 0
        var records: [TurnMetric] = []
        for step in 0..<min(24, keys.count) {
            guard budget > 0 else { break }
            let key = keys[(nextSessionIndex + step) % keys.count]
            guard var session = sessions[key] else { continue }
            do {
                let currentEventDate = (try? sessionFileDate(at: URL(fileURLWithPath: key))) ?? session.eventsModifiedAt
                if currentEventDate != session.eventsModifiedAt {
                    session.eventsModifiedAt = currentEventDate
                    session.stableSince = nil
                }
                let newEvents = try session.events.poll(maxBytes: min(Self.eventBatchBytes, budget))
                records += newEvents
                let eventBytesRead = session.events.bytesReadLastPoll
                budget -= eventBytesRead
                if eventBytesRead > 0 || !session.events.isCaughtUp { session.stableSince = nil }

                let usageURL = URL(fileURLWithPath: key).deletingLastPathComponent().appendingPathComponent("usage.json")
                let usageDate = try? sessionFileDate(at: usageURL)
                if let usageDate, usageDate != session.usageModifiedAt,
                   let size = try? sessionFileSize(at: usageURL), size <= Self.maximumUsageBytes, size <= budget {
                    let data = try Data(contentsOf: usageURL, options: [.mappedIfSafe])
                    budget -= data.count
                    session.usageReadCheckedAt = now
                    if session.usageData != data {
                        session.usageData = data
                        session.stableSince = nil
                    }
                    session.usageModifiedAt = usageDate
                } else if usageDate == nil {
                    session.usageModifiedAt = nil
                    session.usageData = nil
                    session.stableSince = nil
                }

                if session.events.isCaughtUp, session.usageData != nil {
                    if session.stableSince == nil { session.stableSince = now }
                    if let stableSince = session.stableSince,
                       now.timeIntervalSince(stableSince) >= Self.snapshotStabilitySeconds,
                       let usageData = session.usageData {
                        records += session.events.reconcile(snapshot: usageData)
                    }
                }
                sessions[key] = session
            } catch {
                sessions[key] = session
            }
            processed += 1
        }
        nextSessionIndex = (nextSessionIndex + processed) % keys.count
        var unique: [String: TurnMetric] = [:]
        for record in records { unique[record.id] = record }
        return unique.values.sorted { $0.completedAt > $1.completedAt }
    }

    public func status() -> (rootAvailable: Bool, sessions: Int) {
        (rootIsAvailable, watchedSessionCount)
    }

    private func discoverSessions(now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            rootIsAvailable = false
            sessions.removeAll(keepingCapacity: false)
            watchedSessionCount = 0
            return
        }
        rootIsAvailable = true
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadUnknown) }
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent == "events.jsonl" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate,
                  modified >= now.addingTimeInterval(-MetricHistory.retention) else { continue }
            candidates.append((url, modified))
        }
        candidates.sort { $0.modified > $1.modified }
        var seen = Set<String>()
        for candidate in candidates.prefix(Self.maximumFiles) {
            let key = candidate.url.standardizedFileURL.path
            seen.insert(key)
            if var session = sessions[key] {
                if session.eventsModifiedAt != candidate.modified {
                    session.eventsModifiedAt = candidate.modified
                    session.stableSince = nil
                }
                sessions[key] = session
            } else {
                sessions[key] = WatchedSession(
                    events: IncrementalJSONLMetricReader(url: candidate.url),
                    eventsModifiedAt: candidate.modified
                )
            }
        }
        sessions = sessions.filter { seen.contains($0.key) }
        watchedSessionCount = sessions.count
        nextSessionIndex = sessions.isEmpty ? 0 : nextSessionIndex % sessions.count
    }

    private func sessionFileDate(at url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values.contentModificationDate else { throw CocoaError(.fileReadUnknown) }
        return date
    }

    private func sessionFileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown) }
        return size
    }
}
