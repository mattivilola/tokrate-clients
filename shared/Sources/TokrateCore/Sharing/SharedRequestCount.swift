import Foundation

/// One entry of an upload's `requestCounts` (contract "Request outcomes (0.1.22)"): how many requests of
/// one client, version, model and provider succeeded and how many failed on the provider's side during
/// one five-minute period (and, from 0.1.24, how many were throttled). The complete allowlist: no outcome identifier, message or time finer than the
/// period crosses this boundary.
public struct SharedRequestCount: Encodable, Sendable {
    /// Largest accepted value of one count (the bound the server enforces).
    public static let maximumCount = 10_000

    public let countId: UUID
    public let observedAt: Date
    public let client: String
    public let clientVersion: String
    public let appVersion = SharedSample.appVersion
    public let parserVersion: String
    public let metricVersion = RequestOutcome.metricVersion
    public let model: String
    public let provider: String
    public let succeeded: Int
    public let overloaded: Int
    public let serverError: Int
    /// Always encoded from 0.1.24 (contract "Provider throttling (0.1.24)"), also when 0.
    public let throttled: Int

    /// Nil unless the entry is valid on every rule the server applies: a supported client with its
    /// current parser, a known model (never `unknown`), a hosted provider allowed for the client,
    /// each count from 0 to 10,000 and at least one request in total. The client version falls back to
    /// `unknown`, and the time is floored to its five-minute period.
    public init?(
        countId: UUID = UUID(), observedAt: Date, client: String, clientVersion: String?, parserVersion: String,
        model: String, provider: String, succeeded: Int, overloaded: Int, serverError: Int, throttled: Int
    ) {
        guard RequestOutcome.supports(client: client, parser: parserVersion),
              model != "unknown", model.range(of: RequestOutcome.modelPattern, options: .regularExpression) != nil,
              RequestOutcome.allowedProviders(client: client, parser: parserVersion).contains(provider),
              [succeeded, overloaded, serverError, throttled].allSatisfy({ (0...Self.maximumCount).contains($0) }),
              succeeded + overloaded + serverError + throttled >= 1,
              observedAt.timeIntervalSince1970.isFinite
        else { return nil }
        self.countId = countId
        self.observedAt = Date(timeIntervalSince1970: floor(observedAt.timeIntervalSince1970 / 300) * 300)
        self.client = client
        self.clientVersion = clientVersion.flatMap {
            $0.range(of: RequestOutcome.clientVersionPattern, options: .regularExpression) != nil ? $0 : nil
        } ?? "unknown"
        self.parserVersion = parserVersion
        self.model = model
        self.provider = provider
        self.succeeded = succeeded
        self.overloaded = overloaded
        self.serverError = serverError
        self.throttled = throttled
    }

    /// The entries that carry these totals: one, or several when a field exceeds 10,000, so no entry is
    /// ever sent outside the bounds and no count is lost to clamping. Empty when the identity is not valid
    /// or there is nothing to send.
    static func entries(
        observedAt: Date, client: String, clientVersion: String?, parserVersion: String, model: String, provider: String,
        succeeded: Int, overloaded: Int, serverError: Int, throttled: Int
    ) -> [SharedRequestCount] {
        var remaining = (
            succeeded: max(0, succeeded), overloaded: max(0, overloaded), serverError: max(0, serverError), throttled: max(0, throttled)
        )
        var entries: [SharedRequestCount] = []
        while remaining.succeeded + remaining.overloaded + remaining.serverError + remaining.throttled > 0 {
            let chunk = (
                succeeded: min(remaining.succeeded, maximumCount), overloaded: min(remaining.overloaded, maximumCount),
                serverError: min(remaining.serverError, maximumCount), throttled: min(remaining.throttled, maximumCount)
            )
            guard let entry = SharedRequestCount(
                observedAt: observedAt, client: client, clientVersion: clientVersion, parserVersion: parserVersion, model: model,
                provider: provider, succeeded: chunk.succeeded, overloaded: chunk.overloaded, serverError: chunk.serverError,
                throttled: chunk.throttled
            ) else { return [] }
            entries.append(entry)
            remaining = (
                remaining.succeeded - chunk.succeeded, remaining.overloaded - chunk.overloaded,
                remaining.serverError - chunk.serverError, remaining.throttled - chunk.throttled
            )
        }
        return entries
    }

    private enum CodingKeys: String, CodingKey {
        case countId, observedAt, client, clientVersion, appVersion, parserVersion, metricVersion, model, provider
        case succeeded, overloaded, serverError, throttled
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(countId, forKey: .countId)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(client, forKey: .client)
        try container.encode(clientVersion, forKey: .clientVersion)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(parserVersion, forKey: .parserVersion)
        try container.encode(metricVersion, forKey: .metricVersion)
        try container.encode(model, forKey: .model)
        try container.encode(provider, forKey: .provider)
        try container.encode(succeeded, forKey: .succeeded)
        try container.encode(overloaded, forKey: .overloaded)
        try container.encode(serverError, forKey: .serverError)
        try container.encode(throttled, forKey: .throttled)
    }
}
