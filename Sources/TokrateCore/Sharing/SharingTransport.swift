import CryptoKit
import Foundation

public protocol SharingIdentity: Sendable {
    /// Called only after explicit consent, never during launch or local-only operation.
    func loadOrCreate() throws -> Data
}

public protocol SharingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionSharingTransport: SharingTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else { throw URLError(.badServerResponse) }
        return (data, response.statusCode)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum SampleRequest {
    public static func signed(samples: [SharedSample], privateKey: Data, sentAt: Date, baseURL: URL) throws -> URLRequest {
        let body = try SampleEnvelope(sentAt: sentAt, samples: samples).encoded()
        guard !samples.isEmpty, samples.count <= 50, body.count <= 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        var request = URLRequest(url: baseURL.appendingPathComponent("samples"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key.publicKey.rawRepresentation.base64EncodedString(), forHTTPHeaderField: "X-Tokrate-Key")
        request.setValue(try key.signature(for: body).base64EncodedString(), forHTTPHeaderField: "X-Tokrate-Signature")
        return request
    }
}
