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
    }

    static let maximumSteps = 100_000
    static let maximumExecutors = 10_000
    /// A blob above this size is not loaded: SQLite reports it as missing (an oversized generation
    /// decodes to nothing).
    static let maximumBlobBytes = 8 * 1_048_576

    private let database: ReadOnlySQLiteDatabase

    init(url: URL) throws {
        database = try ReadOnlySQLiteDatabase(url: url)
    }

    func close() { database.close() }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try database.readTransaction(body)
    }

    /// Every step in index order. The length guard runs in SQL, so a value above `maximumBlobBytes` is
    /// never loaded; it, like more than `maximumSteps` rows, makes the database unreadable.
    func steps() throws -> [StepRow] {
        var oversized = false
        var seen = 0
        let rows = try database.query(
            "SELECT idx, has_subtrajectory, CASE WHEN length(metadata) <= ?1 THEN metadata END, length(metadata) > ?1 FROM steps ORDER BY idx LIMIT ?2",
            bindings: [.integer(Int64(Self.maximumBlobBytes)), .integer(Int64(Self.maximumSteps + 1))]
        ) { row -> StepRow? in
            seen += 1
            if row.int64(3) == 1 { oversized = true }
            guard let idx = row.int64(0), let metadata = row.blob(2) else { return nil }
            return StepRow(idx: idx, hasSubtrajectory: (row.int64(1) ?? 0) != 0, metadata: metadata)
        }
        guard seen <= Self.maximumSteps else { throw LimitError.tooManySteps }
        guard !oversized else { throw LimitError.oversizedStep }
        return rows
    }

    /// Every executor row in index order; one above `maximumBlobBytes` is skipped unloaded (its
    /// execution stays unfinished as far as Tokrate knows), and more than `maximumExecutors` rows make
    /// the database unreadable.
    func executorMetadata() throws -> [BlobRow] {
        var seen = 0
        let rows = try database.query(
            "SELECT idx, CASE WHEN length(data) <= ?1 THEN data END FROM executor_metadata ORDER BY idx LIMIT ?2",
            bindings: [.integer(Int64(Self.maximumBlobBytes)), .integer(Int64(Self.maximumExecutors + 1))]
        ) { row -> BlobRow? in
            seen += 1
            guard let idx = row.int64(0), let data = row.blob(1) else { return nil }
            return BlobRow(idx: idx, data: data)
        }
        guard seen <= Self.maximumExecutors else { throw LimitError.tooManyExecutors }
        return rows
    }

    /// One generation's blob, or `nil` when no such row exists (yet). A row with a NULL or oversized
    /// blob reads as empty data, which decodes to nothing. Generation rows can be large (megabytes),
    /// so callers fetch only the ones they need.
    func generationData(idx: Int64) throws -> Data? {
        try database.queryFirst(
            "SELECT CASE WHEN length(data) <= ?1 THEN data END FROM gen_metadata WHERE idx = ?2",
            bindings: [.integer(Int64(Self.maximumBlobBytes)), .integer(idx)]
        ) { row in
            .some(row.blob(0) ?? Data())
        }
    }

    func parentReferenceCount() throws -> Int {
        try database.queryFirst("SELECT COUNT(*) FROM parent_references") { row in row.int64(0).map(Int.init) } ?? 0
    }
}
