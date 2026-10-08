import CoreFoundation
import CryptoKit
import Foundation

/// Folds completed primary work turns with the matching Grok usage ledger snapshot.
/// Subagent output remains part of the reported root work-turn total, so these turns delegate nothing
/// beyond it and are final at emission (`delegatedOutputTokens` 0). Grok records output tokens per
/// turn only, so response speed is a whole-turn average over the turn's generation windows
/// (`loop_started` to the next `tool_started` or `turn_ended`); turns with nested agents carry none.
struct GrokSessionParser: JSONLMetricParser {
    private static let earlyTimestampTolerance: TimeInterval = 1
    private static let maximumUsageWriteDelay: TimeInterval = 60

    private struct TurnStart: Sendable {
        let number: Int
        let startedAt: Date
        let sessionID: String
        /// The session's reasoning effort when this turn began while Tokrate was already watching.
        let effort: String?
    }

    private enum Frame: Sendable {
        case primary(Int)
        case subagent
        case ambiguous
    }

    /// Time the primary agent spent generating: one window per model call. Tool runs and permission
    /// waits fall between a call's `tool_started` and the next `loop_started`.
    private struct GenerationWindows: Sendable {
        private static let maximumWindows = 1_024
        private var openedAt: Date?
        private(set) var durations: [TimeInterval] = []
        private(set) var hasNestedAgent = false
        private(set) var isInvalid = false

        mutating func loopStarted(at timestamp: Date) {
            close(at: timestamp)
            openedAt = timestamp
        }

        /// Closes the open window. Later `tool_started` events of the same call find none open.
        mutating func close(at timestamp: Date) {
            guard let start = openedAt else { return }
            openedAt = nil
            if durations.count >= Self.maximumWindows { isInvalid = true; return }
            durations.append(timestamp.timeIntervalSince(start))
        }

        mutating func markNestedAgent() { hasNestedAgent = true }
        mutating func markInvalid() { isInvalid = true }
    }

    private struct EndedTurn: Sendable {
        let start: TurnStart
        let endedAt: Date
        let outcome: String
        let windows: GenerationWindows
    }

    /// The ledger row's model-call count, which must equal the number of generation windows.
    private enum ModelCalls: Equatable, Sendable {
        case absent
        case count(Int)
        case malformed
    }

    private struct UsageTurn: Equatable, Sendable {
        let endedAt: Date
        let outputTokens: Int
        let reasoningTokens: Int?
        /// `inputTokens` (including cached tokens) and `cachedReadTokens` of the ledger row.
        let inputTokens: Int?
        let cachedReadTokens: Int?
        let model: String?
        let modelCalls: ModelCalls
    }

    private var sourceIdentity: String
    private var sessionID: String?
    private var stack: [Frame] = []
    private var activeStart: TurnStart?
    private var windows = GenerationWindows()
    private var seenPrimaryTurnNumbers: Set<Int> = []
    private var ambiguousTurnNumbers: Set<Int> = []
    private var endedTurns: [Int: EndedTurn] = [:]
    private var usageTurns: [Int: UsageTurn] = [:]
    private var emittedTurnNumbers: Set<Int> = []
    private var pendingEndedTurnNumbers: Set<Int> = []
    private var nextPrimaryStartAtByTurnNumber: [Int: Date] = [:]
    private var currentEffort: String?
    private var isLiveRead = false

    init(sourceIdentity: String) { self.sourceIdentity = sourceIdentity }

    mutating func reset(sourceIdentity: String) {
        self.sourceIdentity = sourceIdentity
        sessionID = nil
        stack.removeAll(keepingCapacity: true)
        activeStart = nil
        windows = GenerationWindows()
        seenPrimaryTurnNumbers.removeAll(keepingCapacity: true)
        ambiguousTurnNumbers.removeAll(keepingCapacity: true)
        endedTurns.removeAll(keepingCapacity: true)
        usageTurns.removeAll(keepingCapacity: true)
        emittedTurnNumbers.removeAll(keepingCapacity: true)
        pendingEndedTurnNumbers.removeAll(keepingCapacity: true)
        nextPrimaryStartAtByTurnNumber.removeAll(keepingCapacity: true)
        isLiveRead = false
    }

    mutating func readWillBegin(wasCaughtUp: Bool) { isLiveRead = wasCaughtUp }

    mutating func observeSessionEffort(_ effort: String?) { currentEffort = effort }

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
        } else if type == "loop_started" || type == "tool_started" {
            consumeGeneration(event, isLoopStart: type == "loop_started")
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
            // events.jsonl numbers turns from 0 while the usage ledger numbers them from 1.
            // Convert at this boundary so every join below uses the event numbering; a
            // ledger number below 1 cannot map to any event turn.
            guard let ledgerNumber = nonnegativeInteger(entry["turnNumber"]), ledgerNumber >= 1,
                  let endedAt = parseDate(entry["endedAt"]),
                  let outputTokens = nonnegativeInteger(entry["outputTokens"]),
                  endedAt <= updatedAt.addingTimeInterval(1),
                  entry["usageIsIncomplete"] as? Bool != true,
                  validTurnCount(entry["turnCount"])
            else { continue }
            let number = ledgerNumber - 1
            let model = soleModelUsage(entry["modelUsage"])
            let reasoningTokens = nonnegativeInteger(entry["reasoningTokens"]).flatMap { $0 <= outputTokens ? $0 : nil }
            let value = UsageTurn(
                endedAt: endedAt, outputTokens: outputTokens, reasoningTokens: reasoningTokens,
                inputTokens: nonnegativeInteger(entry["inputTokens"]),
                cachedReadTokens: nonnegativeInteger(entry["cachedReadTokens"]), model: model,
                modelCalls: modelCalls(entry["modelCalls"])
            )
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
            guard ResponseSpeed.isPlausibleTurnThroughput(outputTokens: usage.outputTokens, durationSeconds: duration) else { continue }
            let rate = Double(usage.outputTokens) / duration
            let response = responseTiming(eventTurn.windows, usage: usage, turnDuration: duration)
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
                parserVersion: "grok-session-v2",
                metricVersion: "grok-observed-work-turn-v1",
                reasoningOutputTokens: usage.reasoningTokens,
                sourceKind: "primary",
                provider: "unknown",
                reasoningEffort: confirmedEffort(eventTurn.start),
                responseOutputTokens: response?.tokens,
                responseDurationSeconds: response?.seconds,
                responseCount: response?.count,
                delegatedOutputTokens: 0,
                // `cacheCreationTokens` is always 0 in Grok's ledger: not reported, never 0.
                inputTokens: usage.inputTokens,
                cacheReadInputTokens: usage.cachedReadTokens,
                cacheWriteInputTokens: nil
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
            if activeStart != nil { windows.markNestedAgent() }
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
        let start = TurnStart(number: number, startedAt: timestamp, sessionID: id, effort: isLiveRead ? currentEffort : nil)
        activeStart = start
        windows = GenerationWindows()
        stack = [.primary(number)]
    }

    /// `loop_started` opens a model call's window (closing any still open); the call's first
    /// `tool_started` closes it. Only the primary agent's own events count.
    private mutating func consumeGeneration(_ event: [String: Any], isLoopStart: Bool) {
        guard stack.count == 1, case .primary(let number) = stack[0], activeStart?.number == number else { return }
        guard let timestamp = parseDate(event["ts"]) else {
            windows.markInvalid()
            return
        }
        if isLoopStart { windows.loopStarted(at: timestamp) } else { windows.close(at: timestamp) }
    }

    private mutating func consumeEnd(_ event: [String: Any]) {
        guard let timestamp = parseDate(event["ts"]), let frame = stack.popLast() else { return }
        guard stack.isEmpty else { return }
        guard case .primary(let number) = frame, let start = activeStart, start.number == number else {
            activeStart = nil
            return
        }
        activeStart = nil
        var turnWindows = windows
        turnWindows.close(at: timestamp)
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
        endedTurns[number] = EndedTurn(start: start, endedAt: timestamp, outcome: outcome, windows: turnWindows)
        pendingEndedTurnNumbers.insert(number)
    }

    private mutating func invalidateActivePrimary() {
        if let activeStart { ambiguousTurnNumbers.insert(activeStart.number) }
        activeStart = nil
    }

    /// The effort lives in a per-session file the user can change between turns. It is attributed only
    /// when it was observed as the turn began and is unchanged now; backfilled turns stay unknown.
    private func confirmedEffort(_ start: TurnStart) -> String? {
        guard let effort = start.effort, effort == currentEffort else { return nil }
        return effort
    }

    private func soleModelUsage(_ value: Any?) -> String? {
        guard let models = value as? [String: Any] else { return nil }
        let names = models.keys.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard names.count == 1 else { return nil }
        let name = names[0]
        return safeIdentifier(name, maximum: 80)
    }

    /// Grok reports output tokens per turn, so the turn's total over its summed generation windows is the
    /// only response measurement available. Anything that does not add up fails closed.
    private func responseTiming(
        _ windows: GenerationWindows, usage: UsageTurn, turnDuration: TimeInterval
    ) -> (tokens: Int, seconds: Double, count: Int)? {
        let count = windows.durations.count
        guard !windows.hasNestedAgent, !windows.isInvalid, count >= 1,
              windows.durations.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= ResponseSpeed.maximumDurationSeconds })
        else { return nil }
        switch usage.modelCalls {
        case .absent: break
        case .count(let calls): guard calls == count else { return nil }
        case .malformed: return nil
        }
        let tokens = usage.outputTokens
        let seconds = windows.durations.reduce(0, +)
        guard tokens >= ResponseSpeed.minimumOutputTokens * count,
              seconds <= turnDuration + 0.000_001,
              Double(tokens) / seconds <= ResponseSpeed.maximumTokensPerSecond
        else { return nil }
        return (tokens, min(seconds, turnDuration), count)
    }

    private func modelCalls(_ value: Any?) -> ModelCalls {
        guard let value, !(value is NSNull) else { return .absent }
        return nonnegativeInteger(value).map { .count($0) } ?? .malformed
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
        return TranscriptTimestamp.parse(string)
    }
}

public actor GrokSessionMonitor {
    private static let maximumUsageBytes = 262_144
    private static let maximumSummaryBytes = 65_536
    private static let snapshotStabilitySeconds: TimeInterval = 4
    /// Safety net for a folder watcher that missed a change; `noteChanges` normally triggers discovery.
    private static let discoveryInterval = CodexSessionMonitor.discoveryInterval
    private static let watchedFileNames: Set<String> = ["events.jsonl", "usage.json", "summary.json"]

    private struct WatchedSession {
        var events: IncrementalJSONLMetricReader<GrokSessionParser>
        var eventsModifiedAt: Date
        var usageModifiedAt: Date?
        var usageData: Data?
        var stableSince: Date?
        /// The `stableSince` whose snapshot was last reconciled; a session is due once that lags behind.
        var reconciledSince: Date?
        var usageReadCheckedAt = Date.distantPast
        var summaryModifiedAt: Date?
        var summarySize: Int?
        var summaryEffort: String?
    }

    private let root: URL
    private let scope: MonitorScope
    private var sessions: [String: WatchedSession] = [:]
    private var lastDiscovery = Date.distantPast
    private var needsDiscovery = false
    /// Sessions a folder watcher reported as changed; they are serviced first.
    private var changedSessions: Set<String> = []
    /// Sessions not visited since the last discovery. Discovery is the safety net for a missed event, so
    /// every session is read once after it; between discoveries only changed ones are.
    private var unvisitedSessions: Set<String> = []
    private var nextSessionIndex = 0
    private(set) var rootIsAvailable = false
    private(set) var watchedSessionCount = 0

    public init(root: URL, scope: MonitorScope = .live) {
        self.root = root
        self.scope = scope
    }

    /// Marks what a folder watcher reported so the next poll reads it: a change to a known session's
    /// event log, usage or summary file services that session first, and a new session or a lost event
    /// triggers discovery. Returns whether anything is now pending.
    @discardableResult
    public func noteChanges(_ change: SessionFolderChange) -> Bool {
        var noted = change.mustRescan
        if change.mustRescan { needsDiscovery = true }
        for path in change.paths {
            let url = URL(fileURLWithPath: path)
            guard Self.watchedFileNames.contains(url.lastPathComponent) else { continue }
            let key = url.deletingLastPathComponent().appendingPathComponent("events.jsonl").standardizedFileURL.path
            if var session = sessions[key] {
                if url.lastPathComponent == "events.jsonl" {
                    if let modified = SessionFolderChange.modificationDate(ofRegularFileAt: path) {
                        session.eventsModifiedAt = modified
                    } else {
                        needsDiscovery = true
                    }
                }
                session.stableSince = nil
                sessions[key] = session
                changedSessions.insert(key)
                noted = true
            } else if url.lastPathComponent == "events.jsonl", SessionFolderChange.isDiscoverable(path, under: root),
                      SessionFolderChange.modificationDate(ofRegularFileAt: path) != nil {
                needsDiscovery = true
                noted = true
            }
        }
        return noted
    }

    /// `now` while a session has unread events or is yet to be visited after a discovery, a change was
    /// reported or a discovery is waiting; else when the
    /// earliest session's snapshot has been stable long enough to reconcile; nil when nothing is pending.
    public func nextPollDeadline(now: Date) -> Date? {
        if needsDiscovery || !changedSessions.isEmpty || !unvisitedSessions.isEmpty { return now }
        guard rootIsAvailable else { return nil }
        var earliest: Date?
        for session in sessions.values {
            if !session.events.isCaughtUp { return now }
            guard let stableSince = session.stableSince, session.reconciledSince != stableSince else { continue }
            let due = stableSince.addingTimeInterval(Self.snapshotStabilitySeconds)
            if earliest.map({ due < $0 }) ?? true { earliest = due }
        }
        return earliest
    }

    public func poll(now: Date = .now) throws -> [TurnMetric] {
        if needsDiscovery || now.timeIntervalSince(lastDiscovery) >= Self.discoveryInterval || sessions.isEmpty {
            // Cleared first so a failing enumeration is retried by the safety net, not on every poll.
            needsDiscovery = false
            try discoverSessions(now: now)
            lastDiscovery = now
            unvisitedSessions = Set(sessions.keys)
        }
        guard rootIsAvailable, !sessions.isEmpty else { return [] }

        let keys = sessions.keys.sorted { left, right in
            let a = sessions[left]!.eventsModifiedAt, b = sessions[right]!.eventsModifiedAt
            return a == b ? left < right : a > b
        }
        guard !keys.isEmpty else { return [] }
        var budget = scope.maximumPollBytes
        var processed = 0
        var records: [TurnMetric] = []
        let rotation = (0..<keys.count).map { keys[(nextSessionIndex + $0) % keys.count] }
        // Only sessions with something to do are visited: reported changes and snapshots that have become
        // stable first, then unread events and the sessions yet to be visited after a discovery in round
        // robin, which only advances by the sessions it visited.
        let urgent = Set(rotation.filter { key in
            changedSessions.contains(key) || sessions[key].map { Self.isSnapshotDue($0, now: now) } == true
        })
        let others = rotation.filter { key in
            !urgent.contains(key) && (unvisitedSessions.contains(key) || sessions[key]?.events.isCaughtUp == false)
        }
        for key in (rotation.filter(urgent.contains) + others).prefix(24) {
            guard budget > 0 else { break }
            guard var session = sessions[key] else { continue }
            changedSessions.remove(key)
            unvisitedSessions.remove(key)
            do {
                let currentEventDate = (try? sessionFileDate(at: URL(fileURLWithPath: key))) ?? session.eventsModifiedAt
                if currentEventDate != session.eventsModifiedAt {
                    session.eventsModifiedAt = currentEventDate
                    session.stableSince = nil
                }
                refreshSummaryEffort(of: &session, sessionURL: URL(fileURLWithPath: key).deletingLastPathComponent(), budget: &budget)
                session.events.observeSessionEffort(session.summaryEffort)
                let newEvents = try session.events.poll(maxBytes: min(scope.readerBatchBytes, budget))
                records += newEvents
                let eventBytesRead = session.events.bytesReadLastPoll
                budget -= eventBytesRead
                if eventBytesRead > 0 || !session.events.isCaughtUp { session.stableSince = nil }

                let usageURL = URL(fileURLWithPath: key).deletingLastPathComponent().appendingPathComponent("usage.json")
                let usageDate = try? sessionFileDate(at: usageURL)
                if let usageDate, usageDate != session.usageModifiedAt,
                   let size = try? sessionFileSize(at: usageURL), size <= Self.maximumUsageBytes, size <= budget {
                    // A file that is not a regular one, or grew past the cap, holds no usable snapshot.
                    let data: Data?
                    do { data = try RegularFile.read(usageURL, maximumBytes: Self.maximumUsageBytes) } catch is RegularFile.Failure { data = nil }
                    budget -= data?.count ?? 0
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
                    if let stableSince = session.stableSince, session.reconciledSince != stableSince,
                       now.timeIntervalSince(stableSince) >= Self.snapshotStabilitySeconds,
                       let usageData = session.usageData {
                        records += session.events.reconcile(snapshot: usageData)
                        session.reconciledSince = stableSince
                    }
                }
                sessions[key] = session
            } catch {
                sessions[key] = session
            }
            if !urgent.contains(key) { processed += 1 }
        }
        nextSessionIndex = (nextSessionIndex + processed) % keys.count
        var unique: [String: TurnMetric] = [:]
        for record in records { unique[record.id] = record }
        return unique.values.sorted { $0.completedAt > $1.completedAt }
    }

    private static func isSnapshotDue(_ session: WatchedSession, now: Date) -> Bool {
        guard let stableSince = session.stableSince else { return false }
        return session.reconciledSince != stableSince
            && now.timeIntervalSince(stableSince) >= snapshotStabilitySeconds
    }

    public func status() -> (rootAvailable: Bool, sessions: Int) {
        (rootIsAvailable, watchedSessionCount)
    }

    private func discoverSessions(now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            rootIsAvailable = false
            sessions.removeAll(keepingCapacity: false)
            changedSessions.removeAll()
            unvisitedSessions.removeAll()
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
                  modified >= now.addingTimeInterval(-scope.retention) else { continue }
            candidates.append((url, modified))
        }
        candidates.sort { $0.modified > $1.modified }
        var seen = Set<String>()
        for candidate in candidates.prefix(scope.maximumFiles) {
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
        changedSessions.formIntersection(sessions.keys)
        unvisitedSessions.formIntersection(sessions.keys)
        watchedSessionCount = sessions.count
        nextSessionIndex = sessions.isEmpty ? 0 : nextSessionIndex % sessions.count
    }

    /// Retains only the lowercase `reasoning_effort` string from summary.json; nothing else is read out.
    private func refreshSummaryEffort(of session: inout WatchedSession, sessionURL: URL, budget: inout Int) {
        let summaryURL = sessionURL.appendingPathComponent("summary.json")
        guard let date = try? sessionFileDate(at: summaryURL), let size = try? sessionFileSize(at: summaryURL) else {
            session.summaryModifiedAt = nil
            session.summarySize = nil
            session.summaryEffort = nil
            return
        }
        guard date != session.summaryModifiedAt || size != session.summarySize else { return }
        guard size <= Self.maximumSummaryBytes else {
            session.summaryModifiedAt = date
            session.summarySize = size
            session.summaryEffort = nil
            return
        }
        guard size <= budget else { return }
        // A file that is not a regular one, or grew past the cap, holds no usable summary; any other
        // failure is retried at the next poll.
        let data: Data?
        do { data = try RegularFile.read(summaryURL, maximumBytes: Self.maximumSummaryBytes) } catch is RegularFile.Failure { data = nil } catch { return }
        budget -= data?.count ?? 0
        session.summaryModifiedAt = date
        session.summarySize = size
        session.summaryEffort = data
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["reasoning_effort"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
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
