import Foundation

/// Where `tokrate export-history --out` may write. The command overwrites its destination, so it must
/// never be one of the tool files Tokrate reads, and never something that is not a plain file.
public enum ExportDestination {
    public enum Rejection: Error, Equatable, CustomStringConvertible {
        /// The destination is, or is inside, a folder a coding tool keeps its sessions in.
        case insideSourceFolder(String)
        /// The destination exists and is a folder, FIFO, device or socket.
        case notRegularFile
        /// The destination's folder does not exist.
        case missingFolder

        public var description: String {
            switch self {
            case .insideSourceFolder(let folder):
                "The export file must not be inside \(folder), where a coding tool keeps its data. Choose another --out location."
            case .notRegularFile:
                "The --out path exists and is not a regular file."
            case .missingFolder:
                "The folder of the --out path does not exist."
            }
        }
    }

    /// The destination with symbolic links resolved and `.`/`..` removed, after the checks: not inside
    /// (or equal to) any of `sourceFolders`, and either absent or a regular file. An existing regular
    /// file elsewhere is the user's explicit choice to overwrite.
    public static func validated(_ url: URL, sourceFolders: SourceFolders) throws -> URL {
        let standardized = url.standardizedFileURL
        let folder = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Rejection.missingFolder
        }
        var destination = folder.appendingPathComponent(standardized.lastPathComponent)
        var status = stat()
        // A link at the destination stands for what it points to.
        if lstat(destination.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
            destination = destination.resolvingSymlinksInPath()
        }
        let path = destination.path
        for root in [sourceFolders.codex, sourceFolders.claudeCode, sourceFolders.grokBuild, sourceFolders.antigravity, sourceFolders.openCode] {
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            if path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
                throw Rejection.insideSourceFolder(root.standardizedFileURL.path)
            }
        }
        var target = stat()
        if stat(path, &target) == 0, target.st_mode & S_IFMT != S_IFREG { throw Rejection.notRegularFile }
        return destination
    }

    /// Writes `data` to the validated destination, replacing it in one step, readable by the user alone.
    public static func write(_ data: Data, to url: URL, sourceFolders: SourceFolders) throws {
        try PrivateFile.write(data, to: validated(url, sourceFolders: sourceFolders))
    }
}
