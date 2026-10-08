import CryptoKit
import Foundation

public protocol SharingIdentity: Sendable {
    /// Called only while sharing is requested, including automatic default-on launch; never while sharing is off.
    func loadOrCreate() throws -> Data
}

public protocol SharingTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionSharingTransport: SharingTransport {
    /// A larger response is refused while it streams in, not after it has been buffered.
    static let maximumResponseBytes = 1_048_576
    /// Names the app and its release only. The system default would add the app's build number and the
    /// CFNetwork and Darwin versions.
    static let userAgent = "Tokrate/\(SharedSample.appVersion)"

    /// Fixed, so the user's language preferences (which URLSession would otherwise send as
    /// `Accept-Language`) are not. `Accept-Encoding` stays the system's.
    static let acceptLanguage = "en"
    static let accept = "application/json"

    private let session: URLSession
    public init() {
        self.init(protocolClasses: nil)
    }
    /// `protocolClasses` replaces the network for tests.
    init(protocolClasses: [AnyClass]?) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength <= Self.maximumResponseBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            // Leaving the loop abandons the stream, which cancels the transfer.
            guard data.count < Self.maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
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
