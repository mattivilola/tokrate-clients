import Foundation

/// What a change to a SQLite database looks like on disk: the modification time and size of the
/// database and of its write-ahead log. A source database is re-read only when this changes.
struct DatabaseFileSignature: Equatable, Sendable {
    let databaseModifiedAt: Date
    let databaseSize: Int
    let walModifiedAt: Date?
    let walSize: Int?

    var modifiedAt: Date { max(databaseModifiedAt, walModifiedAt ?? .distantPast) }

    /// The signature of a database file; `nil` when it is missing or not a regular file. The log is
    /// optional.
    static func of(_ databaseURL: URL) -> DatabaseFileSignature? {
        guard let database = attributes(of: databaseURL.path) else { return nil }
        let wal = attributes(of: databaseURL.path + "-wal")
        return DatabaseFileSignature(
            databaseModifiedAt: database.modifiedAt, databaseSize: database.size,
            walModifiedAt: wal?.modifiedAt, walSize: wal?.size
        )
    }

    /// Modification time and size of a regular file; `nil` otherwise.
    static func attributes(of path: String) -> (modifiedAt: Date, size: Int)? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path),
              values[.type] as? FileAttributeType == .typeRegular,
              let modifiedAt = values[.modificationDate] as? Date,
              let size = (values[.size] as? NSNumber)?.intValue else { return nil }
        return (modifiedAt, size)
    }
}
