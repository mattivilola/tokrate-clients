import Foundation
import Network
import XCTest
@testable import TokrateCore

/// A canned network: what the community endpoint answers, and what the client sent and did with it.
private final class StubNetwork: URLProtocol, @unchecked Sendable {
    struct Script {
        var statusCode = 200
        var headers: [String: String] = [:]
        /// Delivered one by one; a chunk is not delivered once the client has stopped the load.
        var chunks: [Data] = []
        /// After this many chunks the stub holds back the rest until the client stops the load (or
        /// five seconds pass), so what the client does after crossing its limit cannot race the stub.
        var holdBackAfter: Int?
        var redirectTo: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]
    nonisolated(unsafe) private static var delivered: [String: Int] = [:]
    nonisolated(unsafe) private static var stopped: [String: Bool] = [:]

    static func prepare(_ script: Script, for name: String) -> URL {
        lock.withLock {
            scripts[name] = script
            requests[name] = nil
            delivered[name] = 0
            stopped[name] = false
        }
        return URL(string: "https://stub.test/\(name)")!
    }

    static func request(_ name: String) -> URLRequest? { lock.withLock { requests[name] } }
    static func deliveredChunks(_ name: String) -> Int { lock.withLock { delivered[name] ?? 0 } }
    static func wasStopped(_ name: String) -> Bool { lock.withLock { stopped[name] ?? false } }

    private var name: String { request.url?.lastPathComponent ?? "" }
    private let state = NSLock()
    private var isStopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = name
        guard let script = Self.lock.withLock({ () -> Script? in
            Self.requests[name] = request
            return Self.scripts[name]
        }) else { return }
        if let target = script.redirectTo {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // A refused redirect leaves the redirect response itself as the result, as on the network.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: script.statusCode, httpVersion: nil, headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            for (index, chunk) in script.chunks.enumerated() {
                if index == script.holdBackAfter {
                    let deadline = Date.now.addingTimeInterval(5)
                    while !state.withLock({ isStopped }), Date.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
                }
                if state.withLock({ isStopped }) { return }
                Self.lock.withLock { Self.delivered[name, default: 0] += 1 }
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.01)
            }
            if !state.withLock({ isStopped }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        state.withLock { isStopped = true }
        let name = name
        Self.lock.withLock { Self.stopped[name] = true }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
    func update(_ change: (inout Value) -> Void) where Value == Data {
        lock.withLock {
            var current = stored ?? Data()
            change(&current)
            stored = current
        }
    }
}

final class SharingTransportTests: XCTestCase {
    private let limit = URLSessionSharingTransport.maximumResponseBytes
    private func transport() -> URLSessionSharingTransport { URLSessionSharingTransport(protocolClasses: [StubNetwork.self]) }

    func testEveryRequestCarriesOnlyTheAppNameAndReleaseAsUserAgent() async throws {
        XCTAssertEqual(URLSessionSharingTransport.userAgent, "Tokrate/\(SharedSample.appVersion)")
        for name in ["board", "samples"] {
            let url = StubNetwork.prepare(.init(chunks: [Data("{}".utf8)]), for: name)
            var request = URLRequest(url: url)
            // Whatever the caller set, the transport's value is the one that goes out.
            request.setValue("Something/1 CFNetwork/9999 Darwin/99", forHTTPHeaderField: "User-Agent")
            _ = try await transport().send(request)
            let sent = try XCTUnwrap(StubNetwork.request(name))
            XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "Tokrate/\(SharedSample.appVersion)")
            XCTAssertFalse(sent.value(forHTTPHeaderField: "User-Agent")?.contains("Darwin") ?? true)
        }
    }

    func testEveryRequestAsksForJSONInEnglishWhateverTheUsersLanguagesAre() async throws {
        for name in ["board", "samples"] {
            let url = StubNetwork.prepare(.init(chunks: [Data("{}".utf8)]), for: name)
            var request = URLRequest(url: url)
            request.setValue("de-DE,fr;q=0.8", forHTTPHeaderField: "Accept-Language")
            _ = try await transport().send(request)
            let sent = try XCTUnwrap(StubNetwork.request(name))
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept-Language"), "en")
        }
    }

    /// What really leaves the process: a loopback server records the raw request head, which includes
    /// the headers CFNetwork adds below URLSession and a protocol stub never sees.
    func testTheHeadersOnTheWireCarryNoLocaleAndNoSystemVersions() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let captured = LockedBox<String>()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            let received = LockedBox<Data>()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                    if let data { received.update { $0.append(data) } }
                    let head = received.value ?? Data()
                    if error != nil || head.range(of: Data("\r\n\r\n".utf8)) != nil {
                        captured.set(String(decoding: head, as: UTF8.self))
                        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    } else {
                        receive()
                    }
                }
            }
            receive()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)

        let (_, code) = try await URLSessionSharingTransport().send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/board")!))
        XCTAssertEqual(code, 200)
        let head = try XCTUnwrap(captured.value).lowercased()
        func header(_ name: String) -> String? {
            head.split(separator: "\r\n").first { $0.hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        XCTAssertEqual(header("accept"), "application/json")
        XCTAssertEqual(header("accept-language"), "en")
        XCTAssertEqual(header("user-agent"), "tokrate/\(SharedSample.appVersion)")
        XCTAssertFalse(head.contains("darwin") || head.contains("cfnetwork"))
    }

    func testABodyUpToTheLimitIsReturnedWithItsStatus() async throws {
        let body = Data(repeating: 0x61, count: limit)
        let url = StubNetwork.prepare(.init(statusCode: 200, chunks: [body]), for: "exact")
        let (data, code) = try await transport().send(URLRequest(url: url))
        XCTAssertEqual(code, 200)
        XCTAssertEqual(data, body)
    }

    func testAnErrorStatusWithASmallBodyIsReturnedNotThrown() async throws {
        let url = StubNetwork.prepare(.init(statusCode: 426, chunks: [Data("upgrade".utf8)]), for: "upgrade")
        let (data, code) = try await transport().send(URLRequest(url: url))
        XCTAssertEqual(code, 426)
        XCTAssertEqual(data, Data("upgrade".utf8))
    }

    func testAnOversizedBodyAbortsTheTransferWhileItStreams() async throws {
        // 8 chunks of 256 KiB: the limit is crossed in the fifth. The stub offers those five, then
        // holds the other three back until the client cancels the transfer.
        let chunk = Data(repeating: 0x61, count: 262_144)
        let url = StubNetwork.prepare(.init(chunks: Array(repeating: chunk, count: 8), holdBackAfter: 5), for: "oversized")
        do {
            _ = try await transport().send(URLRequest(url: url))
            XCTFail("an oversized response must be refused")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
        // The transport stopped reading at the limit and cancelled: the stub sees the cancellation
        // well within its five seconds and never gets to offer the held-back chunks.
        let deadline = Date.now.addingTimeInterval(4)
        while !StubNetwork.wasStopped("oversized"), Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(StubNetwork.wasStopped("oversized"), "the transfer is cancelled, not drained")
        XCTAssertEqual(StubNetwork.deliveredChunks("oversized"), 5, "the remaining chunks are never downloaded")
    }

    func testADeclaredOversizedBodyIsRefusedBeforeAnyByteIsRead() async throws {
        let url = StubNetwork.prepare(.init(headers: ["Content-Length": "\(limit + 1)"], chunks: [Data("x".utf8)]), for: "declared")
        do {
            _ = try await transport().send(URLRequest(url: url))
            XCTFail("an oversized response must be refused")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }

    func testARedirectIsNotFollowed() async throws {
        let target = StubNetwork.prepare(.init(chunks: [Data("elsewhere".utf8)]), for: "target")
        let url = StubNetwork.prepare(.init(redirectTo: target), for: "redirecting")
        let (_, code) = try await transport().send(URLRequest(url: url))
        XCTAssertEqual(code, 302)
        XCTAssertNil(StubNetwork.request("target"), "the redirect target is never requested")
    }
}
