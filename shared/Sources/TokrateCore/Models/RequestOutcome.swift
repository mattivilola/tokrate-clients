import CryptoKit
import Foundation

/// One model request a coding tool finished, as far as the provider is concerned (contract "Request
/// outcomes (0.1.22)"): it succeeded, or it failed because the provider was overloaded or had a server
/// error. Every other failure (the user's own limits, sign-in problems, invalid requests, cancellations,
/// local network failures) is never an outcome.
///
/// Outcomes live in memory only. They are produced beside the `TurnMetric`s, travel from the monitors
/// to the sharing session and are never written to the history file, the dashboard, `tokrate inspect`
/// output or an export. They carry no message text, prompt, path or session identifier: the dedupe key
/// is a SHA-256 digest of the source identifiers.
public struct RequestOutcome: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case succeeded
        case overloaded
        case serverError
    }

    /// The measurement definition of every request count.
    public static let metricVersion = "request-outcome-v1"

    /// The sample parser each client's outcomes belong to; the only parser version an outcome may carry.
    static let parserVersions: [String: String] = [
        "claude-code": "claude-transcript-v4",
        "codex": "codex-rollout-v2",
        "opencode": "opencode-db-v1",
        "kimi-code": "kimi-wire-v1"
    ]

    /// The hosted providers each client reports outcomes for. `unknown` is never one of them: a custom
    /// gateway, a local server or an unknown route is the user's own infrastructure.
    static func allowedProviders(client: String) -> Set<String> {
        switch client {
        case "claude-code": ["anthropic", "amazon-bedrock", "google-vertex"]
        case "codex": ["openai"]
        case "opencode": ["anthropic", "openai", "google", "xai"]
        case "kimi-code": ["moonshot"]
        default: []
        }
    }

    static let modelPattern = "^[a-zA-Z0-9._-]{1,80}$"
    static let clientVersionPattern = "^[a-zA-Z0-9.+_-]{1,40}$"

    /// Local deduplication key, never uploaded.
    public let dedupeKey: String
    public let occurredAt: Date
    public let client: String
    public let clientVersion: String
    public let parserVersion: String
    public let model: String
    public let provider: String
    public let kind: Kind

    /// Nil unless the outcome could be uploaded as part of a request count: a supported client with its
    /// current parser version, a model as the sample rules send it (never `unknown`) and a hosted
    /// provider allowed for the client. A client version that does not match the sample rules is
    /// `unknown`.
    public init?(
        dedupeKey: String, occurredAt: Date, client: String, clientVersion: String?, parserVersion: String,
        model: String?, provider: String?, kind: Kind
    ) {
        guard !dedupeKey.isEmpty, Self.parserVersions[client] == parserVersion,
              let model, model != "unknown", model.range(of: Self.modelPattern, options: .regularExpression) != nil,
              let provider, Self.allowedProviders(client: client).contains(provider)
        else { return nil }
        self.dedupeKey = dedupeKey
        self.occurredAt = occurredAt
        self.client = client
        self.clientVersion = clientVersion.flatMap {
            $0.range(of: Self.clientVersionPattern, options: .regularExpression) != nil ? $0 : nil
        } ?? "unknown"
        self.parserVersion = parserVersion
        self.model = model
        self.provider = provider
        self.kind = kind
    }

    /// The digest of the identifiers that make one outcome unique.
    static func key(_ parts: String...) -> String {
        SHA256.hexDigest(of: (["request-outcome"] + parts).joined(separator: "|"))
    }
}
