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

    private func makeStore(records: [TurnMetric] = []) -> HistoryStore {
        HistoryStore(
            persistenceURL: root.appendingPathComponent("history.json"),
            codexFolder: root.appendingPathComponent("default-codex", isDirectory: true),
            claudeProjectsFolder: root.appendingPathComponent("default-claude", isDirectory: true),
            grokSessionsFolder: root.appendingPathComponent("default-grok", isDirectory: true),
            antigravityDataFolder: root.appendingPathComponent("default-gemini", isDirectory: true),
            openCodeDataFolder: root.appendingPathComponent("default-opencode", isDirectory: true),
            sharingPreferences: SharingPreferences(
                session: SharingSession(identity: StubIdentity(), transport: StubTransport()),
                store: StubPreferenceStore()
            ),
            defaults: defaults,
            initialRecords: records
        )
    }

    private func turn(
        _ id: String, secondsAgo: Double, model: String = "claude-opus-5-5", provider: String = "anthropic",
        client: String = "claude-code", parser: String = "claude-transcript-v4", metricVersion: String = "claude-observed-turn-v1",
        turnSpeed: Double = 20, responseSpeed: Double? = 100
    ) -> TurnMetric {
        TurnMetric(
            id: id, completedAt: Date.now.addingTimeInterval(-secondsAgo), model: model, outputTokens: 1_000, durationSeconds: 1_000 / turnSpeed,
            codexTTFTSeconds: nil, turnThroughputTPS: turnSpeed, client: client, clientVersion: "1.0", parserVersion: parser,
            metricVersion: metricVersion, sourceKind: "primary", provider: provider,
            responseOutputTokens: responseSpeed.map { _ in 800 }, responseDurationSeconds: responseSpeed.map { 800 / $0 },
            responseCount: responseSpeed == nil ? nil : 2
        )
    }

    /// The menu-bar value must equal what the popover gauge shows for the same store state.
    private func assertReadoutMatchesPopover(_ store: HistoryStore, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let snapshot = DashboardSnapshot(
            records: store.records, range: .day, selection: store.dashboardSelection, activeModel: store.activeModel,
            clientFilter: store.clientFilter, providerFilter: store.providerFilter
        )
        let popover = snapshot.heroReading(live: store.liveSpeed, liveGroup: store.liveSpeed == nil ? nil : store.menuBarReadout.group)
        let expected = store.dashboardSelection.isAllModels ? "Compare" : popover.value.map { String(format: "%.1f tok/s", $0) } ?? "— tok/s"
        XCTAssertEqual(store.menuBarReadout.speedText, expected, message, file: file, line: line)
        XCTAssertEqual(store.menuBarReadout.tool, store.dashboardSelection.isAllModels ? nil : popover.client.map(CodingTool.named), message, file: file, line: line)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    func testLiveResponsesDriveTheMenuBarReadoutAndAutoModel() throws {
        let store = makeStore()
        defer { store.stopMonitoring() }
        let now = Date.now
        func response(_ id: String, _ secondsAgo: Double, model: String, provider: String, client: String, tokens: Int, speed: Double) -> LiveResponse {
            LiveResponse(id: id, model: model, provider: provider, client: client, sourceKind: "primary", metricVersion: "turn-v1",
                         reasoningEffort: nil, completedAt: now.addingTimeInterval(-secondsAgo), outputTokens: tokens, durationSeconds: Double(tokens) / speed)
        }
        XCTAssertEqual(store.dashboardSelection, .auto)
        XCTAssertEqual(store.menuBarReadout, .unavailable)
        store.startMonitoring()
        XCTAssertEqual(store.menuBarReadout.speedText, "— tok/s")

        store.recordLiveResponses((0..<6).map { response("c\($0)", Double($0) * 20 + 5, model: "claude-opus-5-5", provider: "anthropic", client: "claude-code", tokens: 600, speed: 100 + Double($0)) }, now: now)
        XCTAssertEqual(store.activeModel, ResponseGroupKey(model: "claude-opus-5-5", provider: "anthropic"))
        XCTAssertEqual(store.menuBarReadout.speedText, "102.0 tok/s", "median of the five latest of 100...105")
        XCTAssertEqual(store.menuBarReadout.maker, .anthropic)
        XCTAssertEqual(store.liveSpeed?.responseCount, 5)

        // Pinning a model without live responses shows a dash with that model's badge.
        store.dashboardSelection = .cohort(ModelCohort(model: "gpt-5-codex", provider: "openai", clientVersion: nil))
        XCTAssertEqual(store.menuBarReadout.speedText, "— tok/s")
        XCTAssertEqual(store.menuBarReadout.maker, .openAI)
        store.dashboardSelection = .all
        XCTAssertEqual(store.menuBarReadout.speedText, "Compare")
        store.dashboardSelection = .autoTool("codex")
        XCTAssertNil(store.activeModel, "Claude responses do not count within Codex")
        store.dashboardSelection = .auto
        XCTAssertNotNil(store.activeModel)
        XCTAssertEqual(DashboardSelection.restored(from: defaults.string(forKey: "dashboardModelSelection")), .auto)

        store.stopMonitoring()
        XCTAssertEqual(store.menuBarReadout, .unavailable)
        XCTAssertNil(store.liveSpeed)
    }

    func testMenuBarShowsTheLatestTurnWithoutLiveResponsesAndMatchesThePopover() throws {
        let claude = turn("claude", secondsAgo: 900, responseSpeed: 100)
        let codex = turn("codex", secondsAgo: 600, model: "gpt-5-codex", provider: "openai", client: "codex", parser: "codex-rollout-v2", metricVersion: "turn-v1", responseSpeed: 60)
        let grok = turn("grok", secondsAgo: 300, model: "grok-4.7", provider: "unknown", client: "grok-build", parser: "grok-session-v2", metricVersion: "grok-observed-work-turn-v1", responseSpeed: 70)
        let store = makeStore(records: [claude, codex, grok])
        defer { store.stopMonitoring() }
        store.startMonitoring()

        // No live response: the latest turn with response data, with its maker and tool.
        XCTAssertEqual(store.menuBarReadout.speedText, "70.0 tok/s")
        XCTAssertEqual(store.menuBarReadout.maker, .xAI)
        XCTAssertEqual(store.menuBarReadout.tool, CodingTool.named("grok-build"))
        XCTAssertTrue(store.menuBarReadout.accessibilityLabel.contains("response speed of the latest turn: 70.0 tokens per second"))
        assertReadoutMatchesPopover(store, "auto")

        store.dashboardSelection = .autoTool("codex")
        XCTAssertEqual(store.menuBarReadout.speedText, "60.0 tok/s")
        XCTAssertEqual(store.menuBarReadout.tool, CodingTool.named("codex"))
        assertReadoutMatchesPopover(store, "auto in a tool")

        store.dashboardSelection = .cohort(ModelCohort(claude))
        XCTAssertEqual(store.menuBarReadout.speedText, "100.0 tok/s")
        assertReadoutMatchesPopover(store, "pinned")

        store.dashboardSelection = .auto
        store.clientFilter = "claude-code"
        XCTAssertEqual(store.menuBarReadout.speedText, "100.0 tok/s", "filters apply to the readout like the popover")
        assertReadoutMatchesPopover(store, "client filter")
        store.clientFilter = nil
        store.providerFilter = "openai"
        XCTAssertEqual(store.menuBarReadout.speedText, "60.0 tok/s")
        assertReadoutMatchesPopover(store, "provider filter")
        store.providerFilter = nil

        // A live response takes over from the latest turn; once it ages out the turn is back.
        let now = Date.now
        store.recordLiveResponses([
            LiveResponse(id: "live", model: "claude-opus-5-5", provider: "anthropic", client: "claude-code", sourceKind: "primary",
                         metricVersion: "claude-observed-turn-v1", reasoningEffort: nil, completedAt: now.addingTimeInterval(-5), outputTokens: 600, durationSeconds: 4)
        ], now: now)
        XCTAssertEqual(store.menuBarReadout.speedText, "150.0 tok/s")
        XCTAssertEqual(store.menuBarReadout.tool, CodingTool.named("claude-code"))
        assertReadoutMatchesPopover(store, "live")
        store.recordLiveResponses([], now: now.addingTimeInterval(700))
        XCTAssertEqual(store.menuBarReadout.speedText, "70.0 tok/s")
    }

    func testMenuBarShowsAFallbackAndDashOnlyWithoutAnyMeasurement() {
        let store = makeStore(records: [turn("turn-only", secondsAgo: 120, model: "grok-code-fast-1", provider: "xai", client: "grok-build", parser: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1", turnSpeed: 33, responseSpeed: nil)])
        defer { store.stopMonitoring() }
        XCTAssertEqual(store.menuBarReadout, .unavailable, "paused")
        store.startMonitoring()
        XCTAssertEqual(store.menuBarReadout.speedText, "33.0 tok/s")
        XCTAssertTrue(store.menuBarReadout.accessibilityLabel.contains("turn speed of the latest turn"))
        assertReadoutMatchesPopover(store, "turn only")
        store.stopMonitoring()
        XCTAssertEqual(store.menuBarReadout, .unavailable)

        let empty = makeStore()
        defer { empty.stopMonitoring() }
        empty.startMonitoring()
        XCTAssertEqual(empty.menuBarReadout.speedText, "— tok/s")
        XCTAssertNil(empty.menuBarReadout.tool)
    }

    func testGrokTurnsFeedTheLiveStreamAndAutoInGrokBuildShowsAValue() {
        let store = makeStore(records: [turn("older", secondsAgo: 3_600, model: "grok-4.7", provider: "unknown", client: "grok-build", parser: "grok-session-v2", metricVersion: "grok-observed-work-turn-v1", responseSpeed: 50)])
        defer { store.stopMonitoring() }
        store.startMonitoring()
        store.dashboardSelection = .autoTool("grok-build")
        XCTAssertEqual(store.menuBarReadout.speedText, "50.0 tok/s")

        let fresh = turn("fresh", secondsAgo: 20, model: "grok-4.7", provider: "unknown", client: "grok-build", parser: "grok-session-v2", metricVersion: "grok-observed-work-turn-v1", responseSpeed: 80)
        let liveEntry = LiveResponse(turn: fresh)
        XCTAssertNotNil(liveEntry)
        store.recordLiveResponses(liveEntry.map { [$0] } ?? [])
        XCTAssertEqual(store.activeModel, ResponseGroupKey(model: "grok-4.7", provider: "unknown"))
        XCTAssertEqual(store.liveSpeed?.responseCount, 1)
        XCTAssertEqual(store.menuBarReadout.speedText, "80.0 tok/s")
        XCTAssertEqual(store.menuBarReadout.tool, CodingTool.named("grok-build"))
        assertReadoutMatchesPopover(store, "grok live")
    }

    func testDefaultsApplyUntilAFolderIsChosen() {
        let store = makeStore()
        for kind in SourceFolderKind.allCases { XCTAssertFalse(store.hasCustomFolder(for: kind)) }
        XCTAssertEqual(store.folder(for: .claudeCode).lastPathComponent, "default-claude")
        XCTAssertEqual(store.folder(for: .grokBuild).lastPathComponent, "default-grok")
        XCTAssertEqual(store.folder(for: .antigravity).lastPathComponent, "default-gemini")
        XCTAssertEqual(store.folder(for: .openCode).lastPathComponent, "default-opencode")
        XCTAssertEqual(store.sourceStatuses.map(\.client), ["codex", "claude-code", "grok-build", "antigravity", "opencode"])
        XCTAssertEqual(store.sourceStatuses.last?.title, "OpenCode")
        XCTAssertEqual(store.sourceStatuses.last?.isFound, false)
        XCTAssertEqual(SourceFolderKind.antigravity.folderNoun, "data folder")
        XCTAssertEqual(SourceFolderKind.openCode.folderNoun, "data folder")
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

    func testAntigravityFolderIsFoundOnlyWithAConversationsFolderAndIsPersisted() throws {
        let store = makeStore()
        let chosen = try makeFolder("custom-gemini")
        store.selectFolder(chosen, for: .antigravity)
        XCTAssertEqual(store.sourceStatuses.first { $0.client == "antigravity" }?.isFound, false, "a data folder without Antigravity conversations is not a source")
        XCTAssertEqual(store.sourceStatuses.first { $0.client == "antigravity" }?.detail, "Custom folder")
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent("antigravity-cli/conversations", isDirectory: true), withIntermediateDirectories: true)
        store.resetFolder(for: .antigravity)
        store.selectFolder(chosen, for: .antigravity)
        XCTAssertEqual(store.sourceStatuses.first { $0.client == "antigravity" }?.isFound, true)
        XCTAssertEqual(defaults.string(forKey: "sourceFolderPath.antigravity"), chosen.path)

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.hasCustomFolder(for: .antigravity))
        XCTAssertEqual(relaunched.folder(for: .antigravity).resolvingSymlinksInPath().path, chosen.path)
        relaunched.resetFolder(for: .antigravity)
        XCTAssertNil(defaults.string(forKey: "sourceFolderPath.antigravity"))
        XCTAssertEqual(relaunched.folder(for: .antigravity).lastPathComponent, "default-gemini")
    }

    func testOpenCodeFolderIsFoundOnlyWithTheDatabaseAndIsPersisted() throws {
        let store = makeStore()
        let chosen = try makeFolder("custom-opencode")
        store.selectFolder(chosen, for: .openCode)
        XCTAssertEqual(store.sourceStatuses.first { $0.client == "opencode" }?.isFound, false, "a data folder without opencode.db is not a source")
        XCTAssertEqual(store.sourceStatuses.first { $0.client == "opencode" }?.detail, "Custom folder")
        try Data("db".utf8).write(to: chosen.appendingPathComponent("opencode.db"))
        store.resetFolder(for: .openCode)
        store.selectFolder(chosen, for: .openCode)
        XCTAssertEqual(store.sourceStatuses.first { $0.client == "opencode" }?.isFound, true)
        XCTAssertEqual(defaults.string(forKey: "sourceFolderPath.opencode"), chosen.path)

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.hasCustomFolder(for: .openCode))
        XCTAssertEqual(relaunched.folder(for: .openCode).resolvingSymlinksInPath().path, chosen.path)
        XCTAssertFalse(relaunched.hasCustomFolder(for: .antigravity), "choosing one tool leaves the others on their defaults")
        relaunched.resetFolder(for: .openCode)
        XCTAssertNil(defaults.string(forKey: "sourceFolderPath.opencode"))
        XCTAssertEqual(relaunched.folder(for: .openCode).lastPathComponent, "default-opencode")
    }

    func testOpenCodeShowsAnyRawProviderIdWithAGreyBadgeButKeepsMakerFromTheModel() {
        XCTAssertEqual(ModelCohort.clientTitle("opencode"), "OpenCode")
        XCTAssertEqual(CodingTool.named("opencode").chip, "OC")
        for provider in ["openrouter", "kimi-for-coding", "myomlx", "opencode", "amazon-bedrock"] {
            XCTAssertEqual(ModelMaker(model: "moonshotai/kimi-k2.5", provider: provider), .unknown, provider)
        }
        XCTAssertEqual(ModelCohort.providerTitle("kimi-for-coding"), "kimi-for-coding")
        XCTAssertEqual(ModelCohort.providerTitle("openrouter"), "openrouter")
        XCTAssertEqual(ModelMaker(model: "claude-sonnet-4-5", provider: "kimi-for-coding"), .anthropic, "the model id decides first")
        XCTAssertEqual(ModelMaker(model: "gemini-3.8-flash", provider: "openrouter"), .google)
        XCTAssertNil(ModelMaker.unknown.letter, "no letter: a grey dot")
        func id(_ provider: String, model: String = "claude-sonnet-4-5") -> String? {
            ModelCohort(model: model, provider: provider, clientVersion: "1.18.31", reasoningEffort: nil, client: "opencode",
                        parserVersion: "opencode-db-v1", metricVersion: "opencode-observed-turn-v1").communityBoardID
        }
        XCTAssertNotNil(id("anthropic"))
        XCTAssertNotNil(id("google", model: "gemini-3.8-flash"))
        XCTAssertNil(id("openrouter"), "gateway providers have no community board")
        XCTAssertNil(id("anthropic", model: "moonshotai/kimi-k2.5"), "a model id with a path is not shared")
        let cohort = ModelCohort(model: "moonshotai/kimi-k2.5", provider: "openrouter", clientVersion: "1.14.21", reasoningEffort: nil, client: "opencode",
                                 parserVersion: "opencode-db-v1", metricVersion: "opencode-observed-turn-v1")
        XCTAssertEqual(ModelCohort(id: cohort.id), cohort, "cohort ids round-trip a vendor path and a raw provider")
        XCTAssertEqual(cohort.measurement, .turn)
        XCTAssertTrue(cohort.detailLabel.contains("provider openrouter"))
    }

    func testAntigravityNamesAndBoardIdentity() {
        XCTAssertEqual(ModelCohort.clientTitle("antigravity"), "Antigravity")
        XCTAssertEqual(ModelCohort.providerTitle("google"), "Google")
        func id(_ provider: String, client: String) -> String? {
            ModelCohort(model: "gemini-3.8-flash", provider: provider, clientVersion: nil, reasoningEffort: "medium", client: client,
                        parserVersion: "antigravity-conversation-v1", metricVersion: "antigravity-observed-execution-v1").communityBoardID
        }
        XCTAssertEqual(id("google", client: "antigravity"), #"["gemini-3.8-flash","google","unknown","antigravity-conversation-v1","antigravity-observed-execution-v1","medium","antigravity"]"#)
        XCTAssertNotNil(id("unknown", client: "antigravity"))
        XCTAssertNil(id("google", client: "codex"))
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
        XCTAssertNil(id("amazon-bedrock", client: "codex", parser: "codex-rollout-v2", metric: "turn-v1"))
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
