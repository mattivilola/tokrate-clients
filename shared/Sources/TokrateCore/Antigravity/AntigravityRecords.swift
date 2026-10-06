import Foundation

// Decoders for the three blob kinds Tokrate reads from an Antigravity conversation database. They are
// not a public API and have no published schema, so every decoder reads only the field numbers the
// metric contract lists ("Antigravity (0.1.18)") and reports anything unexpected instead of guessing.
// Prompts, responses, paths and identifiers other than execution ids never leave the blob.

/// A protobuf `Timestamp` as nanoseconds since the Unix epoch, which keeps durations exact.
struct AntigravityInstant: Comparable, Hashable, Sendable {
    let nanoseconds: Int64

    /// Seconds from 1970-01-02 to 2100: a value outside it is not a plausible conversation time.
    private static let validSeconds: ClosedRange<Int64> = 86_400...4_102_444_800

    /// Decodes a message with seconds in field 1 and nanoseconds in field 2 (proto3: absent is 0).
    init?(_ message: ProtobufMessage) {
        guard let seconds = message.proto3Varint(1), let nanos = message.proto3Varint(2),
              let signedSeconds = Int64(exactly: seconds), Self.validSeconds.contains(signedSeconds),
              nanos < 1_000_000_000 else { return nil }
        nanoseconds = signedSeconds * 1_000_000_000 + Int64(nanos)
    }

    var date: Date { Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000) }

    func seconds(since earlier: AntigravityInstant) -> TimeInterval {
        Double(nanoseconds - earlier.nanoseconds) / 1_000_000_000
    }

    static func < (left: Self, right: Self) -> Bool { left.nanoseconds < right.nanoseconds }
}

/// One row of `steps`: what the step's metadata says about timing, execution and model usage.
struct AntigravityStep: Sendable {
    /// Token counts above this are not real usage (the same bound the server applies to a turn).
    private static let maximumTokens: UInt64 = 100_000_000

    struct Usage: Sendable {
        let outputTokens: Int
        let thinkingTokens: Int
    }

    let idx: Int64
    let hasSubtrajectory: Bool
    let createdAt: AntigravityInstant?
    let completedAt: AntigravityInstant?
    let executionID: String?
    /// Present exactly for model calls (the metadata has the usage message, field 9).
    let usage: Usage?
    /// Joins `gen_metadata.idx` (field 20.3); a missing field is generation 0, as proto3 omits zero.
    let generationIndex: Int64
    /// A field the step needs was present but not decodable; an execution with such a step is skipped.
    let hasUnreadableField: Bool

    var isModelCall: Bool { usage != nil }

    /// `nil` when the blob is not a protobuf message at all.
    init?(row: AntigravityDatabase.StepRow) {
        guard let message = ProtobufMessage(row.metadata) else { return nil }
        idx = row.idx
        hasSubtrajectory = row.hasSubtrajectory
        var unreadable = false

        func instant(_ number: Int) -> AntigravityInstant? {
            guard message.contains(number) else { return nil }
            guard let nested = message.message(number), let value = AntigravityInstant(nested) else {
                unreadable = true
                return nil
            }
            return value
        }
        createdAt = instant(1)
        completedAt = instant(7)

        if message.contains(12) {
            let identifier = message.string(12).flatMap { $0.isEmpty || $0.utf8.count > 128 ? nil : $0 }
            if identifier == nil { unreadable = true }
            executionID = identifier
        } else {
            executionID = nil
        }

        if message.contains(9) {
            if let nested = message.message(9),
               let output = nested.proto3Varint(3), output <= Self.maximumTokens,
               let thinking = nested.proto3Varint(9), thinking <= Self.maximumTokens {
                usage = Usage(outputTokens: Int(output), thinkingTokens: Int(thinking))
            } else {
                usage = nil
                unreadable = true
            }
        } else {
            usage = nil
        }

        if message.contains(20) {
            if let nested = message.message(20), let index = nested.proto3Varint(3), let value = Int64(exactly: index) {
                generationIndex = value
            } else {
                generationIndex = 0
                unreadable = true
            }
        } else {
            generationIndex = 0
        }
        hasUnreadableField = unreadable
    }
}

/// One row of `executor_metadata`: an agent run's state, id and selected model variant.
struct AntigravityExecutor: Sendable {
    /// The only state Tokrate accepts: the run has finished.
    static let finishedState: UInt64 = 4

    let executionID: String
    let state: UInt64
    /// The selected model variant id (field 10.1.28), such as `gemini-3.8-flash-medium`.
    let variantID: String?

    var isFinished: Bool { state == Self.finishedState }

    /// `nil` when the blob is unreadable or carries no execution id.
    init?(row: AntigravityDatabase.BlobRow) {
        guard let message = ProtobufMessage(row.data),
              let state = message.proto3Varint(1),
              let identifier = message.string(9), !identifier.isEmpty, identifier.utf8.count <= 128 else { return nil }
        executionID = identifier
        self.state = state
        variantID = message.message(at: [10, 1])?.string(28).flatMap { AntigravityModelID.isSafe($0) ? $0 : nil }
    }
}

/// One row of `gen_metadata`: the model that produced a generation.
struct AntigravityGeneration: Sendable, Equatable {
    /// The `used_non_gemini_model` key in the generation's key/value pairs.
    private static let nonGeminiKey = "used_non_gemini_model"

    let model: String
    /// The value of `used_non_gemini_model`; `nil` when the key is missing or not `true`/`false`.
    let usedNonGeminiModel: Bool?

    /// `nil` when the blob is unreadable or names no model.
    init?(data: Data) {
        guard let message = ProtobufMessage(data)?.message(1),
              let model = message.string(19), AntigravityModelID.isSafe(model) else { return nil }
        self.model = model
        var flag: Bool?
        for pair in message.repeatedMessages(20) ?? [] where pair.string(1) == Self.nonGeminiKey {
            switch pair.string(2) {
            case "true": flag = true
            case "false": flag = false
            default: flag = nil
            }
        }
        usedNonGeminiModel = flag
    }

    /// Antigravity serves Gemini models through Google's own API, so its client is the routing evidence;
    /// any other model it offers (a Claude or open model) stays unknown.
    var provider: String {
        model.hasPrefix("gemini-") && usedNonGeminiModel == false ? "google" : "unknown"
    }
}

enum AntigravityModelID {
    /// Model and variant ids are the only strings kept from a blob; anything else is refused.
    static func isSafe(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9._-]{1,80}$", options: .regularExpression) != nil
    }

    /// The effort `e` when the variant id is exactly `model + "-" + e` for an effort Antigravity names
    /// in its variants; `nil` (unknown) for every other variant, such as `claude-opus-4-6-thinking`.
    static func effort(variantID: String?, model: String?) -> String? {
        guard let variantID, let model, variantID.hasPrefix(model + "-") else { return nil }
        let suffix = String(variantID.dropFirst(model.count + 1))
        return ["minimal", "low", "medium", "high", "xhigh", "max"].contains(suffix) ? suffix : nil
    }
}
