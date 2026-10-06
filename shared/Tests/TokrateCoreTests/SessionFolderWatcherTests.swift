import Foundation
import XCTest
@testable import TokrateCore

final class SessionFolderWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Collects what a watcher reports; the handler runs on the watcher's queue.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [SessionFolderChange] = []
        let reported = XCTestExpectation(description: "change reported")

        func record(_ change: SessionFolderChange) {
            lock.withLock { changes.append(change) }
            reported.fulfill()
        }

        func sawPath(_ path: String) -> Bool { lock.withLock { changes.contains { $0.paths.contains(path) } } }
        var count: Int { lock.withLock { changes.count } }
    }

    /// FSEvents may start delivering a moment after the stream is created, so the writer keeps appending
    /// until the change is seen or the task is cancelled.
    private func appendRepeatedly(to file: URL) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                if let handle = try? FileHandle(forWritingTo: file) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("{}\n".utf8))
                    try? handle.close()
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func testReportsAnAppendedFileUnderTheRootAsSpelled() async throws {
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let recorder = Recorder()
        let watcher = try XCTUnwrap(SessionFolderWatcher(root: directory) { recorder.record($0) })
        defer { watcher.stop() }

        let writer = appendRepeatedly(to: file)
        defer { writer.cancel() }
        await fulfillment(of: [recorder.reported], timeout: 5)
        XCTAssertTrue(recorder.sawPath(file.standardizedFileURL.path))
    }

    func testStopEndsDelivery() async throws {
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let recorder = Recorder()
        let watcher = try XCTUnwrap(SessionFolderWatcher(root: directory) { recorder.record($0) })
        let writer = appendRepeatedly(to: file)
        defer { writer.cancel() }
        await fulfillment(of: [recorder.reported], timeout: 5)

        watcher.stop()
        let delivered = recorder.count
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(recorder.count, delivered, "nothing is delivered after stop()")
        watcher.stop()
    }

    func testMissingRootCreatesNoWatcher() {
        XCTAssertNil(SessionFolderWatcher(root: directory.appendingPathComponent("missing", isDirectory: true)) { _ in })
        XCTAssertNil(SessionFolderWatcher(root: URL(fileURLWithPath: #filePath)) { _ in }, "a file is not a folder")
    }

    func testDiscoverablePathsAreBelowTheRootAndOutsideHiddenFolders() {
        XCTAssertTrue(SessionFolderChange.isDiscoverable(directory.appendingPathComponent("a/b.jsonl").standardizedFileURL.path, under: directory))
        XCTAssertFalse(SessionFolderChange.isDiscoverable(directory.appendingPathComponent(".a/b.jsonl").standardizedFileURL.path, under: directory))
        XCTAssertFalse(SessionFolderChange.isDiscoverable(directory.appendingPathComponent("a/.b.jsonl").standardizedFileURL.path, under: directory))
        XCTAssertFalse(SessionFolderChange.isDiscoverable(directory.path + "-sibling/b.jsonl", under: directory))
    }
}
