import TokrateCore
import XCTest

final class PromptSizeBucketsTests: XCTestCase {
    func testDecimalBoundaryBucketsAreSparseOrderedAndReconcile() throws {
        let values = [0, 7_999, 8_000, 31_999, 32_000, 63_999, 64_000, 127_999, 128_000, 255_999, 256_000]
        let requests = values.enumerated().map { index, input in
            PromptSizeRequestUsage(id: "request-\(index)", inputTokens: input, cacheReadInputTokens: input / 2)
        }
        let bins = try XCTUnwrap(PromptSizeBuckets.aggregate(
            requests,
            inputTokens: values.reduce(0, +),
            cacheReadInputTokens: values.reduce(0) { $0 + $1 / 2 }
        ))

        XCTAssertEqual(bins.map(\.bucket), ["under-8k", "8k-32k", "32k-64k", "64k-128k", "128k-256k", "256k-plus"])
        XCTAssertEqual(bins.map(\.requestCount), [2, 2, 2, 2, 2, 1])
        XCTAssertEqual(bins.reduce(0) { $0 + $1.inputTokens }, values.reduce(0, +))
        XCTAssertEqual(bins.reduce(0) { $0 + $1.cacheReadInputTokens }, values.reduce(0) { $0 + $1 / 2 })
        XCTAssertTrue(PromptSizeBuckets.validated(
            bins, inputTokens: values.reduce(0, +), cacheReadInputTokens: values.reduce(0) { $0 + $1 / 2 }
        ))
    }

    func testAggregateRejectsDuplicateIDsMissingTotalsInvalidCountsAndOverflow() {
        XCTAssertNil(PromptSizeBuckets.aggregate(
            [PromptSizeRequestUsage(id: "same", inputTokens: 8_000, cacheReadInputTokens: 0),
             PromptSizeRequestUsage(id: "same", inputTokens: 8_000, cacheReadInputTokens: 0)],
            inputTokens: 16_000, cacheReadInputTokens: 0
        ))
        XCTAssertNil(PromptSizeBuckets.aggregate(
            [PromptSizeRequestUsage(id: "bad", inputTokens: 10, cacheReadInputTokens: 11)],
            inputTokens: 10, cacheReadInputTokens: 11
        ))
        XCTAssertNil(PromptSizeBuckets.aggregate(
            [PromptSizeRequestUsage(id: "one", inputTokens: 10, cacheReadInputTokens: 0)],
            inputTokens: nil, cacheReadInputTokens: 0
        ))
        XCTAssertNil(PromptSizeBuckets.aggregate(
            (0...PromptSizeBuckets.maximumRequests).map {
                PromptSizeRequestUsage(id: "request-\($0)", inputTokens: 0, cacheReadInputTokens: 0)
            },
            inputTokens: 0, cacheReadInputTokens: 0
        ))
        XCTAssertNil(PromptSizeBuckets.aggregate(
            [PromptSizeRequestUsage(id: "overflow", inputTokens: Int.max, cacheReadInputTokens: 0),
             PromptSizeRequestUsage(id: "overflow-2", inputTokens: 1, cacheReadInputTokens: 0)],
            inputTokens: Int.max, cacheReadInputTokens: 0
        ))
        XCTAssertNil(PromptSizeBuckets.aggregate(
            [PromptSizeRequestUsage(id: "too-large", inputTokens: 1_000_000_001, cacheReadInputTokens: 0)],
            inputTokens: 1_000_000_001, cacheReadInputTokens: 0
        ))
    }

    func testValidationRejectsDuplicateUnknownMisorderedAndInfeasibleBins() {
        let under = PromptSizeBucket(bucket: "under-8k", requestCount: 1, inputTokens: 7_999, cacheReadInputTokens: 0)
        let medium = PromptSizeBucket(bucket: "8k-32k", requestCount: 1, inputTokens: 8_000, cacheReadInputTokens: 0)
        XCTAssertFalse(PromptSizeBuckets.validated([under, under], inputTokens: 15_998, cacheReadInputTokens: 0))
        XCTAssertFalse(PromptSizeBuckets.validated([medium, under], inputTokens: 15_999, cacheReadInputTokens: 0))
        XCTAssertFalse(PromptSizeBuckets.validated([
            PromptSizeBucket(bucket: "other", requestCount: 1, inputTokens: 1, cacheReadInputTokens: 0)
        ], inputTokens: 1, cacheReadInputTokens: 0))
        XCTAssertFalse(PromptSizeBuckets.validated([
            PromptSizeBucket(bucket: "under-8k", requestCount: 1, inputTokens: 8_000, cacheReadInputTokens: 0)
        ], inputTokens: 8_000, cacheReadInputTokens: 0))
        XCTAssertFalse(PromptSizeBuckets.validated([
            PromptSizeBucket(bucket: "8k-32k", requestCount: 1, inputTokens: 7_999, cacheReadInputTokens: 0)
        ], inputTokens: 7_999, cacheReadInputTokens: 0))
        XCTAssertFalse(PromptSizeBuckets.validated([
            PromptSizeBucket(bucket: "256k-plus", requestCount: 4_097, inputTokens: 256_000 * 4_097, cacheReadInputTokens: 0)
        ], inputTokens: 256_000 * 4_097, cacheReadInputTokens: 0))
        XCTAssertFalse(PromptSizeBuckets.validated([under], inputTokens: 7_999, cacheReadInputTokens: 1))
        XCTAssertFalse(PromptSizeBuckets.validated(
            [under], inputTokens: 7_999, cacheReadInputTokens: 0, minimumRequestCount: 2
        ))
        XCTAssertFalse(PromptSizeBuckets.validated([
            PromptSizeBucket(bucket: "256k-plus", requestCount: 1, inputTokens: 1_000_000_001, cacheReadInputTokens: 0)
        ], inputTokens: 1_000_000_001, cacheReadInputTokens: 0))
    }

    func testAccumulatorDeduplicatesIdenticalRecordsAndPoisonsConflictsOrMissingUsage() throws {
        var repeated = PromptSizeUsageAccumulator()
        repeated.record(id: "message", inputTokens: 12_000, cacheReadInputTokens: 3_000)
        repeated.record(id: "message", inputTokens: 12_000, cacheReadInputTokens: 3_000)
        XCTAssertEqual(repeated.buckets(inputTokens: 12_000, cacheReadInputTokens: 3_000)?.first?.requestCount, 1)

        var conflicting = PromptSizeUsageAccumulator()
        conflicting.record(id: "message", inputTokens: 12_000, cacheReadInputTokens: 3_000)
        conflicting.record(id: "message", inputTokens: 12_001, cacheReadInputTokens: 3_000)
        XCTAssertNil(conflicting.buckets(inputTokens: 12_000, cacheReadInputTokens: 3_000))

        var missing = PromptSizeUsageAccumulator()
        missing.record(id: "message", inputTokens: nil, cacheReadInputTokens: 0)
        XCTAssertNil(missing.buckets(inputTokens: 0, cacheReadInputTokens: 0))
    }
}
