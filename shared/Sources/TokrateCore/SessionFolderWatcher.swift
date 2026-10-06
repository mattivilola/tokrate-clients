import CoreServices
import Foundation

/// What a `SessionFolderWatcher` saw below its root since the previous callback.
public struct SessionFolderChange: Sendable, Equatable {
    /// Standardized paths of the changed items, spelled under the root the watcher was created with.
    public var paths: Set<String>
    /// Events were dropped or coalesced into "something below changed", so only a full enumeration of
    /// the folder is reliable.
    public var mustRescan: Bool

    public init(paths: Set<String> = [], mustRescan: Bool = false) {
        self.paths = paths
        self.mustRescan = mustRescan
    }
}

extension SessionFolderChange {
    /// True when the monitors' enumeration could pick `path` up: below `root` and outside hidden
    /// folders and files, which the enumeration skips.
    static func isDiscoverable(_ path: String, under root: URL) -> Bool {
        let prefix = root.standardizedFileURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        return !path.dropFirst(prefix.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// The modification date of a regular file; nil when it is gone or not a regular file.
    static func modificationDate(ofRegularFileAt path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        return values.contentModificationDate
    }
}

/// Reports file-system changes below one session folder, so monitors read a finished response when it
/// is written instead of when the next periodic enumeration notices it.
///
/// FSEvents coalesces bursts over `latency`, so a busy writer costs few callbacks. Paths are reported
/// under the root as the caller spelled it: FSEvents delivers resolved paths (`/private/var` for
/// `/var`), which would otherwise never match the monitors' keys.
public final class SessionFolderWatcher: @unchecked Sendable {
    /// More paths than this in one callback are dropped in favor of a rescan request.
    static let maximumPathsPerCallback = 4_096
    private static let latency: CFTimeInterval = 0.5

    private final class Delivery: @unchecked Sendable {
        let handler: @Sendable (SessionFolderChange) -> Void
        let root: String
        let resolvedRoot: String
        private let lock = NSLock()
        private var isStopped = false

        init(handler: @escaping @Sendable (SessionFolderChange) -> Void, root: String, resolvedRoot: String) {
            self.handler = handler
            self.root = root
            self.resolvedRoot = resolvedRoot
        }

        func stop() {
            lock.withLock { isStopped = true }
        }

        func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
            let lossFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagEventIdsWrapped
            )
            var change = SessionFolderChange()
            for (path, flag) in zip(paths, flags) {
                if flag & lossFlags != 0 { change.mustRescan = true }
                change.paths.insert(callerPath(path))
                if change.paths.count > SessionFolderWatcher.maximumPathsPerCallback {
                    change = SessionFolderChange(mustRescan: true)
                    break
                }
            }
            guard !lock.withLock({ isStopped }) else { return }
            handler(change)
        }

        private func callerPath(_ path: String) -> String {
            let spelled = path.hasPrefix(resolvedRoot) ? root + path.dropFirst(resolvedRoot.count) : path
            return URL(fileURLWithPath: spelled).standardizedFileURL.path
        }
    }

    private let delivery: Delivery
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// Nil when `root` is not an existing folder or the stream cannot start. `handler` runs on a private
    /// serial queue.
    public init?(root: URL, handler: @escaping @Sendable (SessionFolderChange) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        delivery = Delivery(handler: handler, root: root.standardizedFileURL.path, resolvedRoot: resolvedRoot)

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let delivery = Unmanaged<Delivery>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            delivery.deliver(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
        }
        // The stream owns one reference for as long as it can call back.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(delivery).toOpaque(),
            retain: nil,
            release: { info in if let info { Unmanaged<Delivery>.fromOpaque(info).release() } },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [resolvedRoot] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags
        ) else {
            Unmanaged.passUnretained(delivery).release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "app.tokrate.session-folder-watcher"))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit { stop() }

    /// Ends delivery. Callbacks already queued are discarded.
    public func stop() {
        delivery.stop()
        let stream = lock.withLock { () -> FSEventStreamRef? in
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
