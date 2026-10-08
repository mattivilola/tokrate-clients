import Foundation

/// One conversation database opened read-only. Only the columns the metric contract allows are ever
/// selected: `steps(idx, has_subtrajectory, metadata)`, `executor_metadata(idx, data)`,
/// `gen_metadata(idx, data)` and the row count of `parent_references`. The payload, trajectory and
/// render columns (which hold prompts, responses and paths) are never read. The access itself is the
/// shared `ReadOnlySQLiteDatabase`.
final class AntigravityDatabase {
    struct StepRow {
        let idx: Int64
        let hasSubtrajectory: Bool
        let metadata: Data
    }

    struct BlobRow {
        let idx: Int64
        let data: Data
    }

    /// Why a database is not read at all: more than Tokrate is willing to hold in memory. The poll
    /// treats it as any unreadable database and retries after a growing delay.
    enum LimitError: Error {
        case tooManySteps
        case tooManyExecutors
        /// A step's metadata is present but above `maximumBlobBytes`, so the steps cannot be attributed safely.
        case oversizedStep
        /// The blobs of one read add up to more than `maximumSnapshotBytes`.
        case tooManyBytes
    }

    static let maximumSteps = 100_000
    static let maximumExecutors = 10_000
    /// A blob above this size is not loaded: SQLite reports it as missing (an oversized generation
    /// decodes to nothing).
    static let maximumBlobBytes = 8 * 1_048_576
    /// A database whose blobs add up to more than this in one read is skipped like one with too many
    /// rows: the row limits alone would allow gigabytes.
    static let maximumSnapshotBytes = 256 * 1_048_576

    private let database: ReadOnlySQLiteDatabase
    private let maximumBytes: Int
    /// Bytes of blob content loaded by this instance's reads (one snapshot).
    private var bytesRead = 0

    init(url: URL, maximumSnapshotBytes: Int = AntigravityDatabase.maximumSnapshotBytes) throws {
        database = try ReadOnlySQLiteDatabase(url: url)
        maximumBytes = maximumSnapshotBytes
    }

    /// Counts a loaded blob against the snapshot's budget; false once the budget is exceeded.
    private func take(_ blob: Data) -> Bool {
        bytesRead += blob.count
        return bytesRead <= maximumBytes
    }

    /// The `has_subtrajectory` flag as SQLite's `numeric` column reads it: any non-zero number, or the
    /// text `true` or `1`, is true. Selected without materializing a value that could not be true: only
    /// a number or short text can be.
    private static let flagColumn = """
        CASE typeof(has_subtrajectory) WHEN 'integer' THEN has_subtrajectory WHEN 'real' THEN has_subtrajectory
        WHEN 'text' THEN CASE WHEN length(has_subtrajectory) <= 16 THEN has_subtrajectory END END
        """

    private static func isTrue(_ row: SQLiteRow, _ column: Int32) -> Bool {
        if let number = row.int64(column) { return number != 0 }
        if let number = row.double(column) { return number != 0 }
        if let text = row.text(column) { return ["true", "1"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        return false
    }

    func close() { database.close() }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try database.readTransaction(body)
    }

    /// Every step in index order. The length guard runs in SQL, so a value above `maximumBlobBytes` is
    /// never loaded; it, more than `maximumSteps` rows, or more than `maximumSnapshotBytes` of blobs
    /// make the database unreadable.
    func steps() throws -> [StepRow] {
        var rows: [StepRow] = []
        var seen = 0
        var failure: LimitError?
        try database.forEachRow(
            "SELECT idx, \(Self.flagColumn), CASE WHEN length(metadata) <= ?1 THEN metadata END, length(metadata) > ?1 FROM steps ORDER BY idx LIMIT ?2",
            bindings: [.integer(Int64(Self.maximumBlobBytes)), .integer(Int64(Self.maximumSteps + 1))]
        ) { row in
            seen += 1
            if seen > Self.maximumSteps { failure = .tooManySteps; return .stop }
            if row.int64(3) == 1 { failure = .oversizedStep; return .stop }
            guard let idx = row.int64(0), let metadata = row.blob(2) else { return .next }
            guard take(metadata) else { failure = .tooManyBytes; return .stop }
            rows.append(StepRow(idx: idx, hasSubtrajectory: Self.isTrue(row, 1), metadata: metadata))
            return .next
        }
        if let failure { throw failure }
        return rows
    }

    /// Every executor row in index order; one above `maximumBlobBytes` is skipped unloaded (its
    /// execution stays unfinished as far as Tokrate knows), and more than `maximumExecutors` rows, or
    /// more than `maximumSnapshotBytes` of blobs, make the database unreadable.
    func executorMetadata() throws -> [BlobRow] {
        var rows: [BlobRow] = []
        var seen = 0
        var failure: LimitError?
        try database.forEachRow(
            "SELECT idx, CASE WHEN length(data) <= ?1 THEN data END FROM executor_metadata ORDER BY idx LIMIT ?2",
            bindings: [.integer(Int64(Self.maximumBlobBytes)), .integer(Int64(Self.maximumExecutors + 1))]
        ) { row in
            seen += 1
            if seen > Self.maximumExecutors { failure = .tooManyExecutors; return .stop }
            guard let idx = row.int64(0), let data = row.blob(1) else { return .next }
            guard take(data) else { failure = .tooManyBytes; return .stop }
            rows.append(BlobRow(idx: idx, data: data))
            return .next
        }
        if let failure { throw failure }
        return rows
    }

    /// One generation's blob, or `nil` when no such row exists (yet). A row with a NULL or oversized
    /// blob reads as empty data, which decodes to nothing. Generation rows can be large (megabytes),
    /// so callers fetch only the ones they need; their bytes count against the snapshot's budget.
    func generationData(idx: Int64) throws -> Data? {
        let data = try database.queryFirst(
            "SELECT CASE WHEN length(data) <= ?1 THEN data END FROM gen_metadata WHERE idx = ?2",
            bindings: [.integer(Int64(Self.maximumBlobBytes)), .integer(idx)]
        ) { row in
            .some(row.blob(0) ?? Data())
        }
        if let data, !take(data) { throw LimitError.tooManyBytes }
        return data
    }

    func parentReferenceCount() throws -> Int {
        try database.queryFirst("SELECT COUNT(*) FROM parent_references") { row in row.int64(0).map(Int.init) } ?? 0
    }
}
