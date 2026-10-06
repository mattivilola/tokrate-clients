import AppKit
import SwiftUI
import XCTest
import TokrateCore
@testable import TokrateApp

/// Offscreen design previews. Skipped unless `TOKRATE_RENDER_PREVIEWS=1`.
///
///     TOKRATE_RENDER_PREVIEWS=1 TOKRATE_PREVIEW_DIR=/some/folder swift test --build-system native -j 2 --filter PreviewRenderTests
///
/// Everything uses synthetic turns, empty temporary session folders, an in-memory sharing
/// preference store, a fake signing identity and a mock transport: no real history, Keychain
/// access or network requests. Views are rendered with `NSHostingView`, so native controls draw.
@MainActor
final class PreviewRenderTests: XCTestCase {
    func testRenderDesignPreviews() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOKRATE_RENDER_PREVIEWS"] == "1", "Set TOKRATE_RENDER_PREVIEWS=1 to render previews.")
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOKRATE_PREVIEW_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tokrate-previews").path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let work = output.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        for dark in [false, true] {
            let mode = dark ? "dark" : "light"

            // Popover: sharing on, community line with an early-data caution.
            let shared = try await makeFixture(work: work, sharing: .contributing, records: PreviewData.records())
            render(MenuBarView(store: shared.store, updates: shared.updates), dark: dark, to: output, name: "popover-\(mode)")
            render(MenuBarView(store: shared.store, updates: shared.updates, showsDetails: true, maximumHeight: 1600), dark: dark, to: output, name: "popover-details-\(mode)")
            shared.store.dashboardSelection = .all
            render(MenuBarView(store: shared.store, updates: shared.updates), dark: dark, to: output, name: "popover-compare-all-\(mode)")
            shared.store.stopMonitoring()

            // Popover: local only, a slower-than-usual cohort selected.
            let local = try await makeFixture(work: work, sharing: .localOnly, records: PreviewData.records(slowLatest: true))
            render(MenuBarView(store: local.store, updates: local.updates, range: .week), dark: dark, to: output, name: "popover-local-week-\(mode)")
            local.store.stopMonitoring()

            // Popover: empty, paused.
            let empty = try await makeFixture(work: work, sharing: .localOnly, records: [], monitoring: false)
            render(MenuBarView(store: empty.store, updates: empty.updates), dark: dark, to: output, name: "popover-empty-\(mode)")

            // Popover: consent pending.
            let pending = try await makeFixture(work: work, sharing: .pending, records: PreviewData.records())
            render(MenuBarView(store: pending.store, updates: pending.updates), dark: dark, to: output, name: "popover-consent-pending-\(mode)")
            pending.store.stopMonitoring()

            // Onboarding.
            for (index, step) in OnboardingStep.allCases.enumerated() {
                let onboarding = try await makeFixture(work: work, sharing: .pending, records: [], monitoring: false)
                render(OnboardingView(store: onboarding.store, step: step), dark: dark, to: output, name: "onboarding-\(index + 1)-\(mode)")
            }

            // Settings.
            for tab in SettingsTab.allCases {
                let settings = try await makeFixture(work: work, sharing: .contributing, records: PreviewData.records())
                render(SettingsView(store: settings.store, updates: settings.updates, tab: tab), dark: dark, to: output, name: "settings-\(tab.rawValue)-\(mode)")
                settings.store.stopMonitoring()
            }
            let consentSettings = try await makeFixture(work: work, sharing: .pending, records: [], monitoring: false)
            render(SettingsView(store: consentSettings.store, updates: consentSettings.updates, tab: .sharing), dark: dark, to: output, name: "settings-sharing-consent-\(mode)")

            // Full history.
            let history = try await makeFixture(work: work, sharing: .contributing, records: PreviewData.records())
            render(HistoryView(store: history.store, updates: history.updates).frame(width: 960, height: 1280), dark: dark, to: output, name: "history-\(mode)", fixedSize: CGSize(width: 960, height: 1280))
            history.store.dashboardSelection = .all
            render(HistoryView(store: history.store, updates: history.updates).frame(width: 960, height: 1100), dark: dark, to: output, name: "history-compare-all-\(mode)", fixedSize: CGSize(width: 960, height: 1100))
            history.store.stopMonitoring()

            // Efficiency indicator: popover chart, compact comparison and the history window comparison.
            let efficiencyRecords = PreviewData.records()
            let efficiencySnapshot = DashboardSnapshot(records: efficiencyRecords, range: .week, selection: .cohort(ModelCohort(efficiencyRecords[0])))
            let efficiencyDay = DashboardSnapshot(records: efficiencyRecords, range: .day, selection: .cohort(ModelCohort(efficiencyRecords[0])))
            let allSnapshot = DashboardSnapshot(records: efficiencyRecords, range: .week, selection: .all)
            let codexRecords = efficiencyRecords.filter { $0.client == "codex" }
            let codexSnapshot = DashboardSnapshot(records: efficiencyRecords, range: .week, selection: .cohort(ModelCohort(codexRecords[0])))
            render(
                VStack(alignment: .leading, spacing: 14) {
                    TrendChartView(snapshot: efficiencySnapshot, range: .constant(.week), compact: true, initialMetric: .efficiency)
                    Divider()
                    TrendChartView(snapshot: efficiencyDay, range: .constant(.day), compact: true, initialMetric: .efficiency)
                    Divider()
                    TrendChartView(snapshot: codexSnapshot, range: .constant(.week), compact: true, initialMetric: .responseSpeed)
                    Divider()
                    SummaryView(snapshot: efficiencySnapshot, compact: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 14).frame(width: MenuBarView.width).background(DashboardStyle.surface),
                dark: dark, to: output, name: "efficiency-chart-\(mode)"
            )
            render(
                CohortComparisonView(snapshot: allSnapshot, range: .constant(.day), initialMetric: .efficiency, compact: true)
                    .padding(.horizontal, 16).padding(.vertical, 14).frame(width: MenuBarView.width).background(DashboardStyle.surface),
                dark: dark, to: output, name: "efficiency-compare-\(mode)"
            )
            render(
                CohortComparisonView(snapshot: allSnapshot, range: .constant(.week), initialMetric: .efficiency, compact: false)
                    .padding(24).frame(width: 720).background(DashboardStyle.bg),
                dark: dark, to: output, name: "efficiency-compare-window-\(mode)"
            )
            render(
                EfficiencyListView(rows: allSnapshot.efficiencyRows, reference: allSnapshot.efficiencyReference, expanded: Set(allSnapshot.efficiencyRows.map(\.id)))
                    .padding(.horizontal, 16).padding(.vertical, 14).frame(width: MenuBarView.width).background(DashboardStyle.surface),
                dark: dark, to: output, name: "efficiency-compare-expanded-\(mode)"
            )
            // Not enough data: nothing reaches the 20-request reference.
            let sparse = Array(PreviewData.records().filter { $0.client == "grok-build" || $0.sourceKind == "subagent" })
            render(
                CohortComparisonView(snapshot: DashboardSnapshot(records: sparse, range: .day, selection: .all), range: .constant(.day), initialMetric: .efficiency, compact: true)
                    .padding(.horizontal, 16).padding(.vertical, 14).frame(width: MenuBarView.width).background(DashboardStyle.surface),
                dark: dark, to: output, name: "efficiency-compare-sparse-\(mode)"
            )

            // Gauge states and brand.
            let first = PreviewData.series[0]
            let cohort = ModelCohort(model: first.model, provider: first.provider, clientVersion: first.clientVersion, reasoningEffort: first.effort, client: first.client, parserVersion: first.parser, metricVersion: first.metric)
            let liveReading = HeroReading(kind: .live, value: 112.4, model: first.model, provider: first.provider, effort: first.effort, chip: nil, completedAt: Date.now.addingTimeInterval(-120), responseCount: 5, cohort: cohort, client: first.client)
            let turnReading = HeroReading(kind: .turnFallback, value: 62.4, model: "grok-code-fast-1", provider: "xai", effort: nil, chip: "Work turn", completedAt: Date.now.addingTimeInterval(-3 * 3_600), responseCount: nil, cohort: ModelCohort(model: "grok-code-fast-1", provider: "xai", clientVersion: nil, client: "grok-build", parserVersion: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1"), client: "grok-build")
            render(
                HStack(alignment: .top, spacing: 24) {
                    ThroughputGaugeView(reading: liveReading, compact: true, delta: SpeedDelta(latest: 112.4, median: MetricStats(values: [98, 104, 110, 108, 101])))
                        .frame(width: 328)
                    ThroughputGaugeView(reading: .empty, compact: true).frame(width: 328)
                    ThroughputGaugeView(reading: turnReading, compact: true).frame(width: 328)
                }
                .padding(24).background(DashboardStyle.surface),
                dark: dark, to: output, name: "gauge-states-\(mode)"
            )
            render(BrandPreview(), dark: dark, to: output, name: "brand-\(mode)")
            render(MenuBarPreview(dark: dark), dark: dark, to: output, name: "menubar-items-\(mode)")
        }
    }

    // MARK: Rendering

    private func render<V: View>(_ view: V, dark: Bool, to directory: URL, name: String, fixedSize: CGSize? = nil) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        hosting.frame = NSRect(x: 0, y: 0, width: fixedSize?.width ?? hosting.fittingSize.width, height: fixedSize?.height ?? 800)
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        var size = fixedSize ?? hosting.fittingSize
        if fixedSize == nil, size.width < 10 { size.width = 600 }
        hosting.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("Could not allocate a bitmap for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return XCTFail("PNG encoding failed for \(name)") }
        do { try data.write(to: directory.appendingPathComponent("\(name).png")) } catch { XCTFail("\(error)") }
        window.contentView = nil
    }

    // MARK: Fixtures

    private enum SharingChoice { case contributing, localOnly, pending }

    private struct Fixture {
        let store: HistoryStore
        let updates: AppUpdates
    }

    private func makeFixture(work: URL, sharing: SharingChoice, records: [TurnMetric], monitoring: Bool = true, live: Bool = true) async throws -> Fixture {
        let root = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        let grok = root.appendingPathComponent("grok-missing", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        let preferences = SharingPreferences(
            session: SharingSession(identity: FakeIdentity(), transport: MockBoardTransport(records: PreviewData.records())),
            store: InMemoryPreferenceStore()
        )
        switch sharing {
        case .contributing:
            preferences.consentToShare(startPolling: false)
            await preferences.session.refresh()
        case .localOnly:
            preferences.chooseLocalOnly()
        case .pending:
            break
        }
        let suite = "tokrate.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = HistoryStore(
            persistenceURL: root.appendingPathComponent("history.json"),
            codexFolder: codex,
            claudeProjectsFolder: claude,
            grokSessionsFolder: grok,
            sharingPreferences: preferences,
            defaults: defaults,
            initialRecords: records
        )
        if monitoring { store.startMonitoring() }
        if monitoring, live { store.recordLiveResponses(PreviewData.liveResponses()) }
        return Fixture(store: store, updates: AppUpdates(info: [:]))
    }
}

// MARK: - Synthetic data

enum PreviewData {
    struct Series {
        let model: String
        let provider: String
        let client: String
        let clientVersion: String
        let parser: String
        let metric: String
        let sourceKind: String
        let effort: String?
        let base: Double
        let spread: Double
        let turns: Int
        let ttft: Bool
        /// Response speed relative to turn speed; nil for sources without per-response timing.
        var responseFactor: Double? = 1.9
        /// Output tokens per turn: `tokenFloor` plus up to `tokenSpan`.
        var tokenFloor = 220
        var tokenSpan = 1_800
        /// Share of a primary turn's output that subagents add on top; subagent records carry none.
        var delegatedShare = 0.0
    }

    static let series: [Series] = [
        Series(model: "claude-opus-4-1", provider: "anthropic", client: "claude-code", clientVersion: "2.1.0", parser: "claude-transcript-v4", metric: "claude-observed-turn-v1", sourceKind: "primary", effort: "high", base: 58, spread: 14, turns: 70, ttft: false, tokenFloor: 900, tokenSpan: 3_600, delegatedShare: 0.35),
        Series(model: "claude-sonnet-4-5", provider: "anthropic", client: "claude-code", clientVersion: "2.1.0", parser: "claude-transcript-v4", metric: "claude-observed-subagent-turn-v1", sourceKind: "subagent", effort: nil, base: 112, spread: 28, turns: 36, ttft: false),
        Series(model: "gpt-5-codex", provider: "openai", client: "codex", clientVersion: "0.159.2", parser: "codex-rollout-v2", metric: "turn-v1", sourceKind: "primary", effort: "medium", base: 74, spread: 16, turns: 55, ttft: true, tokenFloor: 380, tokenSpan: 1_300),
        Series(model: "gpt-5-codex", provider: "openai", client: "codex", clientVersion: "0.159.2", parser: "codex-rollout-v2", metric: "turn-v1", sourceKind: "primary", effort: "high", base: 48, spread: 12, turns: 24, ttft: true, tokenFloor: 1_100, tokenSpan: 2_400),
        Series(model: "grok-code-fast-1", provider: "xai", client: "grok-build", clientVersion: "unknown", parser: "grok-session-v1", metric: "grok-observed-work-turn-v1", sourceKind: "primary", effort: nil, base: 131, spread: 32, turns: 18, ttft: false, responseFactor: nil, delegatedShare: 0.0)
    ]

    /// Deterministic synthetic turns spread over seven days. The first series' latest turn lands two
    /// minutes ago; with `slowLatest` its recent turns are much slower than its baseline.
    static func records(slowLatest: Bool = false, now: Date = .now) -> [TurnMetric] {
        var generator = LCG(seed: 42)
        var records: [TurnMetric] = []
        for (seriesIndex, item) in series.enumerated() {
            for turn in 0..<item.turns {
                // Recent bursts plus a long tail through the week.
                let hoursAgo: Double = turn < item.turns / 2
                    ? Double(turn) * 0.45 + (seriesIndex == 0 ? 0.03 : Double(seriesIndex) * 0.4)
                    : 24 + Double(turn - item.turns / 2) * (144.0 / Double(max(1, item.turns / 2)))
                let noise = (generator.next() - 0.5) * 2 * item.spread
                var speed = max(8, item.base + noise)
                if slowLatest, seriesIndex == 0, hoursAgo < 24 { speed *= 0.5 }
                if seriesIndex == 0, turn == 0 { speed = slowLatest ? 27.5 : 62.4 }
                let tokens = item.tokenFloor + Int(generator.next() * Double(item.tokenSpan))
                let responseTokens = item.responseFactor.map { _ in Int(Double(tokens) * 0.9) }
                let responseSpeed = item.responseFactor.map { speed * $0 }
                records.append(TurnMetric(
                    id: "preview-\(seriesIndex)-\(turn)",
                    completedAt: now.addingTimeInterval(-hoursAgo * 3_600 - (seriesIndex == 0 && turn == 0 ? 120 : 0)),
                    model: item.model,
                    outputTokens: tokens,
                    durationSeconds: Double(tokens) / speed,
                    codexTTFTSeconds: item.ttft ? 0.5 + generator.next() * 0.9 : nil,
                    turnThroughputTPS: speed,
                    client: item.client,
                    clientVersion: item.clientVersion,
                    parserVersion: item.parser,
                    metricVersion: item.metric,
                    sourceKind: item.sourceKind,
                    provider: item.provider,
                    reasoningEffort: item.effort,
                    responseOutputTokens: responseTokens,
                    responseDurationSeconds: responseTokens.flatMap { tokens in responseSpeed.map { Double(tokens) / $0 } },
                    responseCount: responseTokens == nil ? nil : 1 + turn % 5,
                    // Primary turns are final (Grok: always 0); subagent records have nothing to attribute.
                    delegatedOutputTokens: item.sourceKind == "primary" ? Int(Double(tokens) * item.delegatedShare * (turn % 3 == 0 ? 2 : 0.5)) : nil
                ))
            }
        }
        return records
    }

    /// The last few live responses of the first series' model, finishing within the last two minutes.
    static func liveResponses(now: Date = .now, model: String = series[0].model, provider: String = series[0].provider, speeds: [Double] = [118.2, 104.7, 121.5, 109.9, 112.4]) -> [LiveResponse] {
        speeds.enumerated().map { index, speed in
            LiveResponse(
                id: "live-\(model)-\(index)", model: model, provider: provider, client: "claude-code", sourceKind: "primary",
                metricVersion: "claude-observed-turn-v1", reasoningEffort: "high",
                completedAt: now.addingTimeInterval(-120 + Double(speeds.count - 1 - index) * -20 + 100),
                outputTokens: 600, durationSeconds: 600 / speed
            )
        }
    }

    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
    }
}

private struct FakeIdentity: SharingIdentity {
    func loadOrCreate() throws -> Data { Data(repeating: 9, count: 32) }
}

@MainActor
private final class InMemoryPreferenceStore: SharingPreferenceStore {
    var sharingEnabled: Bool?
    var consentRecord: SharingConsentRecord?
}

/// Serves one board for the first series' cohort and accepts uploads, without any network.
private struct MockBoardTransport: SharingTransport {
    let records: [TurnMetric]

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.lastPathComponent == "board" else { return (Data(), 202) }
        let first = PreviewData.series[0]
        let cohort = ModelCohort(
            model: first.model, provider: first.provider, clientVersion: first.clientVersion, reasoningEffort: first.effort,
            client: first.client, parserVersion: first.parser, metricVersion: first.metric
        )
        let json = """
        {"schemaVersion":1,"generatedAt":"2026-01-01T12:00:00Z","dataAsOf":"2026-01-01T11:55:00Z","collectionEnabled":true,
         "state":"insufficient_data","window":"24h",
         "methodology":{"statistics":"Median of individual completed turns","publicationMode":"early_data","source":"Reported primary-client samples"},
         "cohorts":[{"id":\(String(data: try JSONEncoder().encode(cohort.communityBoardID ?? ""), encoding: .utf8)!),"model":"\(first.model)","provider":"\(first.provider)",
         "clientVersion":"\(first.clientVersion)","reasoningEffort":"\(first.effort ?? "unknown")","client":"\(first.client)",
         "parserVersion":"\(first.parser)","metricVersion":"\(first.metric)","contributors":3,"turns":84,"throughputContributors":3,"throughputTurns":84,
         "medianThroughput":51.3,"minThroughput":18.2,"maxThroughput":96.4}],"alerts":[]}
        """
        return (Data(json.utf8), 200)
    }
}

private struct BrandPreview: View {
    var body: some View {
        HStack(spacing: 28) {
            BrandMarkView(size: 160)
            BrandMarkView(size: 48)
            BrandMarkView(size: 24)
            VStack(spacing: 14) {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template).scaleEffect(5).frame(width: 100, height: 100)
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                    Text("62.4 tok/s").monospacedDigit()
                }
                .foregroundStyle(DashboardStyle.ink)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(DashboardStyle.surface2, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(28)
        .background(DashboardStyle.surface)
    }
}

/// The menu-bar item for each maker, with and without a live value, on a bar-coloured strip.
private struct MenuBarPreview: View {
    let dark: Bool

    private var readouts: [(ModelMaker, String, CodingTool?)] {
        [
            (.anthropic, "112.4 tok/s", CodingTool.named("claude-code")), (.openAI, "74.1 tok/s", CodingTool.named("codex")),
            (.xAI, "131.0 tok/s", CodingTool.named("grok-build")), (.unknown, "— tok/s", nil)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(readouts.enumerated()), id: \.offset) { _, item in
                MenuBarLabel(
                    readout: MenuBarReadout(speedText: item.1, group: nil, maker: item.0, tool: item.2, accessibilityLabel: item.0.title),
                    showsSpeed: true, showsBadge: true, showsToolChip: true
                )
                .foregroundStyle(dark ? Color.white : Color.black)
            }
            let anthropic = MenuBarReadout(speedText: "112.4 tok/s", group: nil, maker: .anthropic, tool: CodingTool.named("claude-code"), accessibilityLabel: "")
            MenuBarLabel(readout: anthropic, showsSpeed: true, showsBadge: false, showsToolChip: true)
                .foregroundStyle(dark ? Color.white : Color.black)
            MenuBarLabel(readout: anthropic, showsSpeed: true, showsBadge: true, showsToolChip: false)
                .foregroundStyle(dark ? Color.white : Color.black)
            MenuBarLabel(readout: anthropic, showsSpeed: true, showsBadge: false, showsToolChip: false)
                .foregroundStyle(dark ? Color.white : Color.black)
        }
        .padding(16)
        .background(dark ? Color(white: 0.16) : Color(white: 0.9))
    }
}
