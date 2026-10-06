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

    private let database: ReadOnlySQLiteDatabase

    init(url: URL) throws {
        database = try ReadOnlySQLiteDatabase(url: url)
    }

    func close() { database.close() }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try database.readTransaction(body)
    }

    func steps() throws -> [StepRow] {
        try database.query("SELECT idx, has_subtrajectory, metadata FROM steps ORDER BY idx") { row in
            guard let idx = row.int64(0), let metadata = row.blob(2) else { return nil }
            return StepRow(idx: idx, hasSubtrajectory: (row.int64(1) ?? 0) != 0, metadata: metadata)
        }
    }

    func executorMetadata() throws -> [BlobRow] {
        try database.query("SELECT idx, data FROM executor_metadata ORDER BY idx") { row in
            guard let idx = row.int64(0), let data = row.blob(1) else { return nil }
            return BlobRow(idx: idx, data: data)
        }
    }

    /// One generation's blob, or `nil` when no such row exists (yet). A row with a NULL or oversized
    /// blob reads as empty data, which decodes to nothing. Generation rows can be large (megabytes),
    /// so callers fetch only the ones they need.
    func generationData(idx: Int64) throws -> Data? {
        try database.queryFirst("SELECT data FROM gen_metadata WHERE idx = ?1", bindings: [.integer(idx)]) { row in
            .some(row.blob(0) ?? Data())
        }
    }

    func parentReferenceCount() throws -> Int {
        try database.queryFirst("SELECT COUNT(*) FROM parent_references") { row in row.int64(0).map(Int.init) } ?? 0
    }
}
