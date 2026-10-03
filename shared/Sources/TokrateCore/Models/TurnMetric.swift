import Foundation

/// A completed Codex turn summarized without its prompt, response, or source path.
public struct TurnMetric: Codable, Identifiable, Hashable, Sendable {
    /// A SHA-256 pseudonym derived locally from the session and turn identifiers.
    public let id: String
    public let completedAt: Date
    public let model: String?
    public let clientVersion: String?
    public let reasoningOutputTokens: Int?
    public let sourceKind: String?
    public let provider: String?
    public let outputTokens: Int
    public let durationSeconds: Double
    public let codexTTFTSeconds: Double?
    public let turnThroughputTPS: Double
    /// Deliberately unavailable until Codex provides a verified generation-only metric.
    public let streamingTPS: Double?

    public init(
        id: String,
        completedAt: Date,
        model: String?,
        outputTokens: Int,
        durationSeconds: Double,
        codexTTFTSeconds: Double?,
        turnThroughputTPS: Double,
        streamingTPS: Double? = nil,
        clientVersion: String? = nil,
        reasoningOutputTokens: Int? = nil,
        sourceKind: String? = nil,
        provider: String? = nil
    ) {
        self.clientVersion = clientVersion
        self.reasoningOutputTokens = reasoningOutputTokens
        self.sourceKind = sourceKind
        self.provider = provider
        self.id = id
        self.completedAt = completedAt
        self.model = model
        self.outputTokens = outputTokens
        self.durationSeconds = durationSeconds
        self.codexTTFTSeconds = codexTTFTSeconds
        self.turnThroughputTPS = turnThroughputTPS
        self.streamingTPS = streamingTPS
    }
}
