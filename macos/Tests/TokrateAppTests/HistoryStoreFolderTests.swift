import XCTest
import TokrateCore
@testable import TokrateApp

/// Custom source folders are persisted in user defaults (path plus security-scoped bookmark data).
/// Everything uses synthetic temporary folders, a throwaway defaults suite and fake sharing seams.
@MainActor
final class HistoryStoreFolderTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "tokrate.folders.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> HistoryStore {
        HistoryStore(
            persistenceURL: root.appendingPathComponent("history.json"),
            codexFolder: root.appendingPathComponent("default-codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("default-claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("default-grok", isDirectory: true),
            sharingPreferences: SharingPreferences(
                session: SharingSession(identity: StubIdentity(), transport: StubTransport()),
                store: StubPreferenceStore()
            ),
            defaults: defaults,
            initialRecords: []
        )
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func testDefaultsApplyUntilAFolderIsChosen() {
        let store = makeStore()
        for kind in SourceFolderKind.allCases { XCTAssertFalse(store.hasCustomFolder(for: kind)) }
        XCTAssertEqual(store.folder(for: .claudeCode).lastPathComponent, "default-claude")
        XCTAssertEqual(store.folder(for: .grokBuild).lastPathComponent, "default-grok")
        XCTAssertEqual(store.sourceStatuses.map(\.client), ["codex", "claude-code", "grok-build"])
    }

    func testChosenFoldersPersistAcrossLaunchesForEveryTool() throws {
        let chosen = Dictionary(uniqueKeysWithValues: try SourceFolderKind.allCases.map { ($0, try makeFolder("custom-\($0.rawValue)")) })
        let store = makeStore()
        for kind in SourceFolderKind.allCases { store.selectFolder(chosen[kind]!, for: kind) }

        let relaunched = makeStore()
        for kind in SourceFolderKind.allCases {
            XCTAssertTrue(relaunched.hasCustomFolder(for: kind), kind.rawValue)
            XCTAssertEqual(relaunched.folder(for: kind).resolvingSymlinksInPath().path, chosen[kind]!.path, kind.rawValue)
        }
        XCTAssertEqual(relaunched.sourceStatuses.first { $0.client == "claude-code" }?.detail, "Custom folder")
        XCTAssertEqual(relaunched.sourceStatuses.first { $0.client == "claude-code" }?.isFound, true)
    }

    func testChoosingOneToolLeavesTheOthersOnTheirDefaults() throws {
        let store = makeStore()
        store.selectFolder(try makeFolder("only-claude"), for: .claudeCode)
        XCTAssertTrue(store.hasCustomFolder(for: .claudeCode))
        XCTAssertFalse(store.hasCustomFolder(for: .codex))
        XCTAssertFalse(store.hasCustomFolder(for: .grokBuild))
        let relaunched = makeStore()
        XCTAssertFalse(relaunched.hasCustomFolder(for: .codex))
        XCTAssertEqual(relaunched.folder(for: .grokBuild).lastPathComponent, "default-grok")
    }

    func testResetReturnsToTheDefaultAndForgetsThePersistedChoice() throws {
        let store = makeStore()
        store.selectFolder(try makeFolder("custom-grok"), for: .grokBuild)
        store.resetFolder(for: .grokBuild)
        XCTAssertFalse(store.hasCustomFolder(for: .grokBuild))
        XCTAssertEqual(store.folder(for: .grokBuild).lastPathComponent, "default-grok")
        XCTAssertNil(defaults.string(forKey: "sourceFolderPath.grok-build"))
        XCTAssertNil(defaults.data(forKey: "sourceFolderBookmark.grok-build"))
        XCTAssertFalse(makeStore().hasCustomFolder(for: .grokBuild))
    }

    func testFolderCannotChangeWhileMonitoring() throws {
        let store = makeStore()
        store.selectFolder(try makeFolder("before"), for: .claudeCode)
        store.startMonitoring()
        defer { store.stopMonitoring() }
        store.selectFolder(try makeFolder("during"), for: .claudeCode)
        XCTAssertEqual(store.folder(for: .claudeCode).lastPathComponent, "before")
        store.resetFolder(for: .claudeCode)
        XCTAssertTrue(store.hasCustomFolder(for: .claudeCode))
    }

    func testProviderTitlesCoverClaudeRoutes() {
        XCTAssertEqual(ModelCohort.providerTitle("anthropic"), "Anthropic")
        XCTAssertEqual(ModelCohort.providerTitle("amazon-bedrock"), "Amazon Bedrock")
        XCTAssertEqual(ModelCohort.providerTitle("google-vertex"), "Google Vertex AI")
        XCTAssertEqual(ModelCohort.providerTitle("openai"), "OpenAI")
        XCTAssertEqual(ModelCohort.providerTitle("xai"), "xAI")
        XCTAssertEqual(ModelCohort.providerTitle("unknown"), "Unknown")
        XCTAssertEqual(ModelCohort.providerTitle(nil), "Unknown")
    }

    func testCommunityBoardIDAcceptsBedrockAndVertexOnlyForClaudeCode() {
        func id(_ provider: String, client: String, parser: String, metric: String) -> String? {
            ModelCohort(model: "claude-sonnet-4-5", provider: provider, clientVersion: "2.1.0", reasoningEffort: nil,
                        client: client, parserVersion: parser, metricVersion: metric).communityBoardID
        }
        XCTAssertNotNil(id("amazon-bedrock", client: "claude-code", parser: "claude-transcript-v3", metric: "claude-observed-turn-v1"))
        XCTAssertNotNil(id("google-vertex", client: "claude-code", parser: "claude-transcript-v3", metric: "claude-observed-turn-v1"))
        XCTAssertNil(id("amazon-bedrock", client: "codex", parser: "codex-rollout-v1", metric: "turn-v1"))
    }
}

private struct StubIdentity: SharingIdentity {
    func loadOrCreate() throws -> Data { Data(repeating: 7, count: 32) }
}

private struct StubTransport: SharingTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 202) }
}

@MainActor
private final class StubPreferenceStore: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
}
