import Foundation

/// Opens the files other tools write (session logs, usage ledgers, summaries) for reading. A path the
/// user's other software controls can be swapped for a FIFO or a device between discovery and the read,
/// and a plain `open` on a FIFO blocks the reader forever. The file is opened without blocking, and
/// only a regular file is kept: the check is made on the open descriptor, so nothing can be swapped
/// in after it. A symbolic link is followed, as it always was, and kept only if its target is a
/// regular file; a link to a FIFO, a device or a folder is refused.
enum RegularFile {
    enum Failure: Error, Equatable {
        /// A FIFO, device, socket or directory (also behind a symbolic link) where a file was expected.
        case notRegular
        /// The file is larger than the caller's cap.
        case tooLarge
    }

    /// The path opened read-only. Throws `CocoaError` when it cannot be opened (a missing file reads as
    /// `fileReadNoSuchFile`, which callers treat as a vanished file) and `Failure.notRegular` for
    /// anything but a regular file.
    static func open(_ url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw CocoaError(.fileReadNoSuchFile)
            case EACCES, EPERM: throw CocoaError(.fileReadNoPermission)
            default: throw CocoaError(.fileReadUnknown)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw Failure.notRegular
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The whole file, read as at most `maximumBytes` plus one byte so a file that grew past its cap
    /// after it was measured is never held in full. Not memory-mapped: a mapping of a file another
    /// process truncates in place raises SIGBUS.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try open(url)
        defer { try? handle.close() }
        let data = try handle.readDraining(upToCount: maximumBytes + 1)
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return data
    }
}
