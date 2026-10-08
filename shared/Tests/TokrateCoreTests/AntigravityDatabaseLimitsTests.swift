import Foundation
import XCTest
@testable import TokrateCore

/// The row and blob bounds of one conversation database read (`AntigravityDatabase`), the same as the
/// Windows/Linux core's.
final class AntigravityDatabaseLimitsTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokrate-antigravity-limits-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("conversation.db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func read<T>(_ body: (AntigravityDatabase) throws -> T) throws -> T {
        let database = try AntigravityDatabase(url: url)
        defer { database.close() }
        return try database.readTransaction { try body(database) }
    }

    /// A database whose `table` holds `rows` one-byte blobs.
    private func filled(_ table: String, rows: Int, column: String, in database: SyntheticAntigravityDatabase? = nil) throws -> SyntheticAntigravityDatabase {
        let database = try database ?? SyntheticAntigravityDatabase(url: url)
        try database.execute("WITH RECURSIVE c(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM c WHERE i < \(rows - 1)) INSERT INTO \(table) (idx, \(column)) SELECT i, x'0A' FROM c")
        return database
    }

    func testTheBoundsMatchTheWindowsAndLinuxCore() {
        XCTAssertEqual(AntigravityDatabase.maximumSteps, 100_000)
        XCTAssertEqual(AntigravityDatabase.maximumExecutors, 10_000)
        XCTAssertEqual(AntigravityDatabase.maximumBlobBytes, 8 * 1_048_576)
    }

    func testADatabaseAtTheStepAndExecutorLimitsIsRead() throws {
        let database = try filled("steps", rows: AntigravityDatabase.maximumSteps, column: "metadata")
        _ = try filled("executor_metadata", rows: AntigravityDatabase.maximumExecutors, column: "data", in: database)
        XCTAssertEqual(try read { try $0.steps() }.count, AntigravityDatabase.maximumSteps)
        XCTAssertEqual(try read { try $0.executorMetadata() }.count, AntigravityDatabase.maximumExecutors)
    }

    func testMoreStepsThanTheLimitMakeTheDatabaseUnreadable() throws {
        _ = try filled("steps", rows: AntigravityDatabase.maximumSteps + 1, column: "metadata")
        XCTAssertThrowsError(try read { try $0.steps() }) { error in
            XCTAssertEqual(error as? AntigravityDatabase.LimitError, .tooManySteps)
        }
    }

    func testMoreExecutorsThanTheLimitMakeTheDatabaseUnreadable() throws {
        _ = try filled("executor_metadata", rows: AntigravityDatabase.maximumExecutors + 1, column: "data")
        XCTAssertThrowsError(try read { try $0.executorMetadata() }) { error in
            XCTAssertEqual(error as? AntigravityDatabase.LimitError, .tooManyExecutors)
        }
    }

    func testAnOversizedStepIsNeverLoadedAndMakesTheDatabaseUnreadable() throws {
        let database = try SyntheticAntigravityDatabase(url: url)
        try database.addStep(SyntheticStep(execution: "exec", created: 0, completed: 1))
        try database.addStep(SyntheticStep(rawMetadata: Data(count: AntigravityDatabase.maximumBlobBytes + 1)))
        XCTAssertThrowsError(try read { try $0.steps() }) { error in
            XCTAssertEqual(error as? AntigravityDatabase.LimitError, .oversizedStep)
        }
    }

    func testAStepAtTheBlobLimitIsLoaded() throws {
        let database = try SyntheticAntigravityDatabase(url: url)
        try database.addStep(SyntheticStep(rawMetadata: Data(count: AntigravityDatabase.maximumBlobBytes)))
        XCTAssertEqual(try read { try $0.steps() }.first?.metadata.count, AntigravityDatabase.maximumBlobBytes)
    }

    func testOversizedExecutorAndGenerationBlobsReadAsMissing() throws {
        let database = try SyntheticAntigravityDatabase(url: url)
        try database.addExecutor(id: "exec", state: 4, variant: nil)
        try database.addExecutorBlob(Data(count: AntigravityDatabase.maximumBlobBytes + 1))
        try database.addGenerationBlob(index: 0, Data(count: AntigravityDatabase.maximumBlobBytes + 1))
        XCTAssertEqual(try read { try $0.executorMetadata() }.count, 1, "only the readable executor is loaded")
        XCTAssertEqual(try read { try $0.generationData(idx: 0) }, Data(), "an oversized generation decodes to nothing")
        XCTAssertNil(try read { try $0.generationData(idx: 1) }, "an absent row is still absent")
    }

    func testTheMonitorTreatsAnOverLimitDatabaseAsUnreadableAndRetriesLater() async throws {
        let folder = url.deletingLastPathComponent()
        let databaseURL = folder.appendingPathComponent("antigravity/conversations/11111111-2222-3333-4444-555555555555.db")
        let database = try SyntheticAntigravityDatabase(url: databaseURL)
        try database.addStep(SyntheticStep(rawMetadata: Data(count: AntigravityDatabase.maximumBlobBytes + 1)))
        let monitor = AntigravityConversationMonitor(root: folder)
        let now = Date.now
        let update = await monitor.poll(now: now)
        XCTAssertTrue(update.metrics.isEmpty)
        _ = await monitor.poll(now: now.addingTimeInterval(1))
        let reads = await monitor.databaseReadCount
        XCTAssertEqual(reads, 1, "the failed read waits out its backoff")
        let deadline = await monitor.nextPollDeadline(now: now)
        XCTAssertNotNil(deadline)
    }

    func testTheSubtrajectoryFlagIsReadLikeSQLitesNumericColumnWithoutLoadingOversizedValues() throws {
        let database = try SyntheticAntigravityDatabase(url: url)
        let values = [
            "1", "0", "1.0", "'true'", "' TRUE '", "'true' || replace(hex(zeroblob(500000)), '00', ' ')",
            "zeroblob(1000000)"
        ]
        for (index, value) in values.enumerated() {
            try database.execute("INSERT INTO steps (idx, has_subtrajectory, metadata) VALUES (\(index), \(value), x'0A')")
        }
        let flags = try read { try $0.steps() }.map(\.hasSubtrajectory)
        XCTAssertEqual(flags, [true, false, true, true, true, false, false])
    }

    func testAReadIsSkippedOnceItsBlobsExceedTheByteBudget() throws {
        let database = try SyntheticAntigravityDatabase(url: url)
        _ = try filled("steps", rows: 10, column: "metadata", in: database)
        try database.execute("INSERT INTO executor_metadata (idx, data) VALUES (0, x'0A')")
        try database.execute("INSERT INTO gen_metadata (idx, data) VALUES (0, x'0A')")

        func readAll(budget: Int) throws {
            let reader = try AntigravityDatabase(url: url, maximumSnapshotBytes: budget)
            defer { reader.close() }
            try reader.readTransaction {
                _ = try reader.steps()
                _ = try reader.executorMetadata()
                _ = try reader.generationData(idx: 0)
            }
        }
        // 10 step bytes, 1 executor byte and 1 generation byte.
        XCTAssertNoThrow(try readAll(budget: 12))
        for budget in [11, 10, 0] {
            XCTAssertThrowsError(try readAll(budget: budget)) { error in
                XCTAssertEqual(error as? AntigravityDatabase.LimitError, .tooManyBytes, "budget \(budget)")
            }
        }
        XCTAssertEqual(AntigravityDatabase.maximumSnapshotBytes, 256 * 1_048_576)
    }

    func testStringsDecodedFromBlobsAreBoundedAt512Bytes() {
        let limit = maximumAntigravityDecodedStringBytes
        XCTAssertEqual(limit, 512)
        func step(execution: String) -> AntigravityStep? {
            AntigravityStep(row: AntigravityDatabase.StepRow(
                idx: 0, hasSubtrajectory: false, metadata: SyntheticStep(execution: execution, created: 1, completed: 2).metadata
            ))
        }
        func executor(id: String, variant: String?) -> AntigravityExecutor? {
            AntigravityExecutor(row: AntigravityDatabase.BlobRow(idx: 0, data: SyntheticAntigravityDatabase.executorBlob(id: id, state: 4, variant: variant)))
        }
        let atLimit = String(repeating: "x", count: limit)
        let overLimit = String(repeating: "x", count: limit + 1)
        // At the limit everything is kept; the execution id is not cut at the old 128 bytes.
        XCTAssertEqual(step(execution: atLimit)?.executionID, atLimit)
        XCTAssertEqual(executor(id: atLimit, variant: nil)?.executionID, atLimit)
        // Over it the blob is unreadable: a step cannot be attributed, an executor never finishes.
        XCTAssertNil(step(execution: overLimit))
        XCTAssertNil(executor(id: overLimit, variant: nil))
        XCTAssertNil(executor(id: "short", variant: overLimit))
        XCTAssertNotNil(executor(id: "short", variant: "gemini-3.8-flash-medium"))
        XCTAssertNil(AntigravityGeneration(data: SyntheticAntigravityDatabase.generationBlob(model: overLimit, nonGemini: "false")))
        XCTAssertNotNil(AntigravityGeneration(data: SyntheticAntigravityDatabase.generationBlob(model: "gemini-3.8-flash", nonGemini: "false")))
    }
}
