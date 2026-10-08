import Foundation

/// When the history file is rewritten while records keep arriving. Every write encodes all records and
/// checkpoints, and a launch replay produces records on every poll, so writes are spaced out instead
/// (the Windows/Linux host does the same, `HISTORY_SAVE_INTERVAL_SECONDS`). Unwritten records are
/// safe: checkpoints are only ever written together with their records, so a crash re-reads the files
/// those records came from.
struct HistorySaveThrottle: Equatable {
    /// The longest an unwritten record waits for the next write.
    static let interval: TimeInterval = 10

    private var hasUnsavedRecords = false
    private var lastSave: Date?

    /// Something the file does not have yet: new records, or records that expired out of the history.
    mutating func noteUnsavedChanges() {
        hasUnsavedRecords = true
    }

    /// Records are waiting and the last write is at least `interval` old, or there was none. A clock
    /// that moved backwards counts as due rather than stalling the write.
    func isDue(now: Date) -> Bool {
        guard hasUnsavedRecords else { return false }
        guard let lastSave else { return true }
        return now < lastSave || now.timeIntervalSince(lastSave) >= Self.interval
    }

    /// When the write falls due, for the poll deadline; nil when nothing is waiting.
    func dueAt(now: Date) -> Date? {
        guard hasUnsavedRecords else { return nil }
        return lastSave.map { $0.addingTimeInterval(Self.interval) } ?? now
    }

    /// Any write counts, whatever triggered it. A failed one is retried after the interval, not at
    /// every poll.
    mutating func didSave(at now: Date, succeeded: Bool) {
        lastSave = now
        if succeeded { hasUnsavedRecords = false }
    }

    /// Forgets the last write, so the first records of a new monitoring session are written at once.
    mutating func reset() {
        self = HistorySaveThrottle()
    }
}
