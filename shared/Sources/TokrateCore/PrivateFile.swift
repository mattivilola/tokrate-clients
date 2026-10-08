import Foundation

/// Files that hold the user's data (the saved history) are readable by the user alone.
public enum PrivateFile {
    /// Replaces the file at `url` with `data` in one step, so a reader sees the old or the new content
    /// and never half of it, and the new file is owner-only (0600) from the moment it exists:
    /// `Data.write(options: .atomic)` creates it with the umask's default, usually 0644. A file that
    /// was written world-readable by an earlier build is replaced by an owner-only one.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var committed = false
        defer { if !committed { unlink(temporary.path) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // The mode above is subject to the umask, which can only remove bits; state it outright.
            guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try handle.write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        committed = true
    }
}
