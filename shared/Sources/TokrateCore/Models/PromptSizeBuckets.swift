import Foundation

/// One sparse bin in the per-model-request prompt-size histogram.
public struct PromptSizeBucket: Codable, Hashable, Sendable {
    public let bucket: String
    public let requestCount: Int
    public let inputTokens: Int
    public let cacheReadInputTokens: Int

    public init(bucket: String, requestCount: Int, inputTokens: Int, cacheReadInputTokens: Int) {
        self.bucket = bucket
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

/// A request's locally keyed prompt usage. `id` is used only to deduplicate and is never serialized.
public struct PromptSizeRequestUsage: Hashable, Sendable {
    public let id: String
    public let inputTokens: Int
    public let cacheReadInputTokens: Int

    public init(id: String, inputTokens: Int, cacheReadInputTokens: Int) {
        self.id = id
        self.inputTokens = inputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

/// Bounded, checked aggregation and validation shared by every local parser and history decoder.
public enum PromptSizeBuckets {
    public static let maximumRequests = 4_096
    public static let maximumTokenCount = 1_000_000_000

    public enum Name: String, CaseIterable, Sendable {
        case under8k = "under-8k"
        case from8kTo32k = "8k-32k"
        case from32kTo64k = "32k-64k"
        case from64kTo128k = "64k-128k"
        case from128kTo256k = "128k-256k"
        case from256k = "256k-plus"

        fileprivate var minimum: Int {
            switch self {
            case .under8k: 0
            case .from8kTo32k: 8_000
            case .from32kTo64k: 32_000
            case .from64kTo128k: 64_000
            case .from128kTo256k: 128_000
            case .from256k: 256_000
            }
        }

        fileprivate var maximum: Int? {
            switch self {
            case .under8k: 7_999
            case .from8kTo32k: 31_999
            case .from32kTo64k: 63_999
            case .from64kTo128k: 127_999
            case .from128kTo256k: 255_999
            case .from256k: nil
            }
        }

        fileprivate func contains(_ tokens: Int) -> Bool {
            tokens >= minimum && (maximum.map { tokens <= $0 } ?? true)
        }
    }

    /// Aggregates one entry per unique request and requires exact reconciliation with the turn's
    /// existing prompt-cache totals. Any incomplete, duplicate, invalid, excessive, or overflowing
    /// source data makes the whole histogram unavailable.
    public static func aggregate(
        _ requests: [PromptSizeRequestUsage],
        inputTokens: Int?,
        cacheReadInputTokens: Int?
    ) -> [PromptSizeBucket]? {
        guard !requests.isEmpty, requests.count <= maximumRequests,
              let inputTokens, let cacheReadInputTokens,
              inputTokens >= 0, inputTokens <= maximumTokenCount,
              cacheReadInputTokens >= 0, cacheReadInputTokens <= maximumTokenCount,
              cacheReadInputTokens <= inputTokens
        else { return nil }

        var ids = Set<String>()
        var counts = Array(repeating: 0, count: Name.allCases.count)
        var inputs = Array(repeating: 0, count: Name.allCases.count)
        var cacheReads = Array(repeating: 0, count: Name.allCases.count)
        for request in requests {
            guard !request.id.isEmpty, ids.insert(request.id).inserted,
                  request.inputTokens >= 0, request.inputTokens <= maximumTokenCount,
                  request.cacheReadInputTokens >= 0, request.cacheReadInputTokens <= maximumTokenCount,
                  request.cacheReadInputTokens <= request.inputTokens,
                  let index = Name.allCases.firstIndex(where: { $0.contains(request.inputTokens) })
            else { return nil }
            let (nextCount, countOverflow) = counts[index].addingReportingOverflow(1)
            let (nextInput, inputOverflow) = inputs[index].addingReportingOverflow(request.inputTokens)
            let (nextRead, readOverflow) = cacheReads[index].addingReportingOverflow(request.cacheReadInputTokens)
            guard !(countOverflow || inputOverflow || readOverflow) else { return nil }
            counts[index] = nextCount
            inputs[index] = nextInput
            cacheReads[index] = nextRead
        }

        let buckets = Name.allCases.indices.compactMap { index -> PromptSizeBucket? in
            guard counts[index] > 0 else { return nil }
            return PromptSizeBucket(
                bucket: Name.allCases[index].rawValue,
                requestCount: counts[index],
                inputTokens: inputs[index],
                cacheReadInputTokens: cacheReads[index]
            )
        }
        return validated(buckets, inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens) ? buckets : nil
    }

    /// Validates persisted or upload-bound bins, including canonical sparse ordering, per-bin
    /// feasibility, the 4,096-request cap, and exact agreement with prompt-cache turn totals.
    public static func validated(
        _ buckets: [PromptSizeBucket]?,
        inputTokens: Int?,
        cacheReadInputTokens: Int?,
        minimumRequestCount: Int = 0
    ) -> Bool {
        guard let buckets, !buckets.isEmpty, buckets.count <= Name.allCases.count,
              let inputTokens, let cacheReadInputTokens,
              inputTokens >= 0, inputTokens <= maximumTokenCount,
              cacheReadInputTokens >= 0, cacheReadInputTokens <= maximumTokenCount,
              cacheReadInputTokens <= inputTokens,
              minimumRequestCount >= 0
        else { return false }

        var previousIndex = -1
        var totalRequests = 0
        var totalInput = 0
        var totalCacheRead = 0
        for bucket in buckets {
            guard let name = Name(rawValue: bucket.bucket),
                  let index = Name.allCases.firstIndex(of: name), index > previousIndex,
                  bucket.requestCount > 0,
                  bucket.inputTokens >= 0, bucket.inputTokens <= maximumTokenCount,
                  bucket.cacheReadInputTokens >= 0, bucket.cacheReadInputTokens <= maximumTokenCount,
                  bucket.cacheReadInputTokens <= bucket.inputTokens
            else { return false }
            previousIndex = index

            let (minimumInput, minimumOverflow) = name.minimum.multipliedReportingOverflow(by: bucket.requestCount)
            guard !minimumOverflow, bucket.inputTokens >= minimumInput else { return false }
            if let maximum = name.maximum {
                let (maximumInput, maximumOverflow) = maximum.multipliedReportingOverflow(by: bucket.requestCount)
                guard !maximumOverflow, bucket.inputTokens <= maximumInput else { return false }
            }

            let (nextRequests, requestOverflow) = totalRequests.addingReportingOverflow(bucket.requestCount)
            let (nextInput, inputOverflow) = totalInput.addingReportingOverflow(bucket.inputTokens)
            let (nextRead, readOverflow) = totalCacheRead.addingReportingOverflow(bucket.cacheReadInputTokens)
            guard !(requestOverflow || inputOverflow || readOverflow), nextRequests <= maximumRequests else { return false }
            totalRequests = nextRequests
            totalInput = nextInput
            totalCacheRead = nextRead
        }
        return totalInput == inputTokens && totalCacheRead == cacheReadInputTokens && totalRequests >= minimumRequestCount
    }
}

/// Parser-side identity handling for bounded requests. A duplicate with conflicting prompt usage, a
/// missing count, or more than 4,096 unique request IDs poisons the whole histogram.
public struct PromptSizeUsageAccumulator: Sendable {
    private struct Observation: Equatable, Sendable {
        let inputTokens: Int?
        let cacheReadInputTokens: Int?
    }

    private var observations: [String: Observation] = [:]
    private var isInvalid = false

    public init() {}

    public mutating func invalidate() { isInvalid = true }

    public mutating func record(id: String, inputTokens: Int?, cacheReadInputTokens: Int?) {
        guard !id.isEmpty else { isInvalid = true; return }
        let observation = Observation(inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens)
        if let existing = observations[id] {
            if existing != observation { isInvalid = true }
            return
        }
        guard observations.count < PromptSizeBuckets.maximumRequests else {
            isInvalid = true
            return
        }
        observations[id] = observation
    }

    public func buckets(inputTokens: Int?, cacheReadInputTokens: Int?) -> [PromptSizeBucket]? {
        guard !isInvalid else { return nil }
        var requests: [PromptSizeRequestUsage] = []
        requests.reserveCapacity(observations.count)
        for (id, observation) in observations {
            guard let input = observation.inputTokens, let cacheRead = observation.cacheReadInputTokens else { return nil }
            requests.append(PromptSizeRequestUsage(id: id, inputTokens: input, cacheReadInputTokens: cacheRead))
        }
        return PromptSizeBuckets.aggregate(requests, inputTokens: inputTokens, cacheReadInputTokens: cacheReadInputTokens)
    }
}
