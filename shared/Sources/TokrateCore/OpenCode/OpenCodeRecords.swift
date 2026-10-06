import Foundation

// Decoded rows of OpenCode's database (contract "OpenCode (0.1.18)"). The layout is not a public API:
// every value is optional, and a message whose counts or timestamps do not read as plain non-negative
// integers is marked malformed so no turn is built on it.

enum OpenCodeVersion {
    /// OpenCode counts reasoning separately from visible output from 1.14; earlier versions are unverified.
    static let floor = (major: 1, minor: 14)

    /// Whether a session's `version` is `major.minor[.patch]` at or above the floor. Anything else
    /// (a prerelease suffix, an empty string) is not measured.
    static func meetsFloor(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        return (major, minor) >= floor
    }
}

enum OpenCodeProvider {
    /// A provider id kept as recorded when it is not one of the four mapped ones.
    private static let rawPattern = "^[a-z0-9][a-z0-9._-]{0,39}$"

    /// The four providers whose records may be shared (with `unknown`); every other id stays local.
    static let shareable: Set<String> = ["anthropic", "openai", "google", "xai", "unknown"]

    /// `anthropic`, `openai`, `google` and `xai` map to themselves; any other id (a gateway such as
    /// `openrouter`, a vendor plan, a local server) is kept as the provider string when it is a plain
    /// lowercase identifier, so the user sees where it ran; a missing or odd id is `unknown`.
    static func map(_ providerID: String?) -> String {
        guard let providerID else { return "unknown" }
        if shareable.contains(providerID) { return providerID }
        return providerID.range(of: rawPattern, options: .regularExpression) != nil ? providerID : "unknown"
    }
}

struct OpenCodeSession: Sendable, Equatable {
    let id: String
    /// Non-nil for a subagent (task tool) session.
    let parentID: String?
    let version: String?

    init(row: OpenCodeDatabase.SessionRow) {
        id = row.id
        parentID = row.parentID
        version = row.version
    }

    var isPrimary: Bool { parentID == nil }
}

/// One `message` row reduced to the numbers and ids the metric needs.
struct OpenCodeMessage: Sendable, Equatable {
    /// Counts above this are not real usage (the bound the server applies to a turn).
    static let maximumTokens: Int64 = 100_000_000
    /// Model ids may contain a vendor path (`moonshotai/kimi-k2.5`) or a tag (`name:8b`).
    private static let modelPattern = "^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,119}$"

    enum Role: Sendable { case user, assistant, other }

    let id: String
    let sessionID: String
    let role: Role
    let parentID: String?
    /// The model id when it is a plain identifier, else nil.
    let model: String?
    /// The mapped provider (see `OpenCodeProvider`).
    let provider: String
    /// `variant` when it is one of the shared reasoning efforts, else nil.
    let effort: String?
    let finish: String?
    let failed: Bool
    /// `time.created` and `time.completed` in milliseconds since the epoch; nil when absent.
    let createdMs: Int64?
    let completedMs: Int64?
    let reasoningTokens: Int?
    /// `tokens.output + tokens.reasoning`; nil when either does not read as a valid count.
    let outputTokens: Int?
    /// Prompt-cache counts, nil when `tokens.input` or `tokens.cache.read` is absent or invalid. The
    /// write count is 0 when absent.
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    /// `time_created` and `time_updated` columns, which drive the index window and the watermark.
    let rowCreatedMs: Int64
    let updatedMs: Int64
    /// An assistant message whose timestamps or output counts are unusable.
    let isMalformed: Bool

    init(row: OpenCodeDatabase.MessageRow) {
        id = row.id
        sessionID = row.sessionID
        role = switch row.role { case "user": .user; case "assistant": .assistant; default: .other }
        parentID = row.parentID
        model = row.modelID.flatMap { $0.range(of: Self.modelPattern, options: .regularExpression) != nil ? $0 : nil }
        provider = OpenCodeProvider.map(row.providerID)
        effort = row.variant.flatMap { ReportedReasoningEffort.isAllowed($0) ? $0 : nil }
        finish = row.finish
        failed = row.hasErrorName
        rowCreatedMs = row.timeCreated
        updatedMs = row.timeUpdated

        var malformed = false
        func timestamp(_ value: OpenCodeDatabase.JSONInteger) -> Int64? {
            switch value {
            case .absent: return nil
            case .value(let number):
                if number > 0 { return number }
                malformed = true
                return nil
            case .invalid:
                malformed = true
                return nil
            }
        }
        func count(_ value: OpenCodeDatabase.JSONInteger) -> (value: Int, isValid: Bool, isPresent: Bool) {
            switch value {
            case .absent: return (0, true, false)
            case .value(let number): return (0...Self.maximumTokens).contains(number) ? (Int(number), true, true) : (0, false, true)
            case .invalid: return (0, false, true)
            }
        }
        createdMs = timestamp(row.created)
        completedMs = timestamp(row.completed)
        let output = count(row.output), reasoning = count(row.reasoning)
        outputTokens = output.isValid && reasoning.isValid ? output.value + reasoning.value : nil
        reasoningTokens = reasoning.isValid ? reasoning.value : nil
        let input = count(row.input), read = count(row.cacheRead), write = count(row.cacheWrite)
        let hasCache = input.isPresent && input.isValid && read.isPresent && read.isValid && write.isValid
        inputTokens = hasCache ? input.value : nil
        cacheReadTokens = hasCache ? read.value : nil
        cacheWriteTokens = hasCache ? write.value : nil
        isMalformed = malformed || outputTokens == nil || (role == .assistant && createdMs == nil)
    }

    var completed: Bool { completedMs != nil }

    /// A `finish` that ends a turn: present, and neither `tool-calls` (more steps follow) nor `unknown`.
    var hasTerminalFinish: Bool {
        guard let finish else { return false }
        return finish != "tool-calls" && finish != "unknown"
    }

    var responseDurationSeconds: TimeInterval? {
        guard let createdMs, let completedMs else { return nil }
        return Double(completedMs - createdMs) / 1_000
    }
}
