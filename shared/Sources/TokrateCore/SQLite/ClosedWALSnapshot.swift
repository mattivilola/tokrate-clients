import Foundation
import SQLite3

/// Conservative fallback for idle WAL-mode files Apple SQLite cannot open without sidecars.
/// It never writes a source or creates a raw database artifact. This is a checked memory copy,
/// not a SQLite transaction: changing or uncertain sources are deferred to a later poll.
enum ClosedWALSnapshot {
    static let maximumBytes = 64 * 1_048_576

    private struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int64
        let modifiedNanos: Int64
        let changed: Int64
        let changedNanos: Int64

        init?(_ value: stat) {
            guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 100,
                  value.st_size <= maximumBytes else { return nil }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    static func open(_ url: URL) throws -> OpaquePointer? {
        let file = try RegularFile.open(url)
        defer { try? file.close() }
        var initial = stat()
        guard fstat(file.fileDescriptor, &initial) == 0, let identity = Identity(initial) else { return nil }
        func stable() -> Bool {
            var descriptor = stat(), path = stat()
            guard fstat(file.fileDescriptor, &descriptor) == 0, stat(url.path, &path) == 0,
                  Identity(descriptor) == identity, Identity(path) == identity else { return false }
            for suffix in ["-wal", "-shm", "-journal"] {
                var sidecar = stat()
                guard lstat(url.path + suffix, &sidecar) == -1, errno == ENOENT else { return false }
            }
            return true
        }
        guard stable(), let first = try file.read(upToCount: Int(identity.size) + 1),
              first.count == Int(identity.size), first.prefix(16) == Data("SQLite format 3\0".utf8),
              first[18] == 2, first[19] == 2, stable() else { return nil }
        try file.seek(toOffset: 0)
        guard let second = try file.read(upToCount: Int(identity.size) + 1), second == first, stable() else { return nil }

        let capacity = first.count + 20
        guard let allocation = sqlite3_malloc64(UInt64(capacity)) else { return nil }
        let bytes = allocation.assumingMemoryBound(to: UInt8.self)
        bytes.initialize(repeating: 0, count: capacity)
        first.copyBytes(to: bytes, count: first.count)
        // SQLite's documented deserialize adaptation, applied only to the memory copy.
        bytes[18] = 1; bytes[19] = 1
        var memory: OpaquePointer?
        guard sqlite3_open(":memory:", &memory) == SQLITE_OK, let memory else {
            sqlite3_free(allocation)
            if let memory { sqlite3_close(memory) }
            return nil
        }
        let result = sqlite3_deserialize(
            memory, "main", bytes, Int64(first.count), Int64(capacity),
            UInt32(SQLITE_DESERIALIZE_READONLY | SQLITE_DESERIALIZE_FREEONCLOSE)
        )
        // FREEONCLOSE also frees the buffer if deserialize fails.
        guard result == SQLITE_OK else { sqlite3_close(memory); return nil }
        var check: OpaquePointer?
        let prepared = sqlite3_prepare_v2(memory, "PRAGMA quick_check(1)", -1, &check, nil)
        let valid = prepared == SQLITE_OK && sqlite3_step(check) == SQLITE_ROW
            && sqlite3_column_text(check, 0).map { String(cString: $0) == "ok" } == true
        sqlite3_finalize(check)
        guard valid, stable() else { sqlite3_close(memory); return nil }
        return memory
    }
}
