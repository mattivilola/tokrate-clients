import SwiftUI
import TokrateCore

/// The menu-bar popover: header, hero speed, trend, your models, community line, footer.
struct MenuBarView: View {
    static let width: CGFloat = 360
    /// The popover grows with its content up to this height, then scrolls.
    static let maximumHeight: CGFloat = 600

    @Bindable var store: HistoryStore
    @ObservedObject var updates: AppUpdates
    var showInitialConsentDashboard: () -> Bool
    private let maximumHeight: CGFloat
    @State private var range: DashboardRange
    @State private var showsDetails: Bool
    @State private var contentHeight: CGFloat = MenuBarView.maximumHeight
    @AppStorage("showMenuBarSpeed") private var showMenuBarSpeed = true
    @AppStorage("showProviderBadge") private var showProviderBadge = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private static let chromeHeight: CGFloat = 104

    init(
        store: HistoryStore,
        updates: AppUpdates,
        showInitialConsentDashboard: @escaping () -> Bool = { false },
        range: DashboardRange = .day,
        showsDetails: Bool = false,
        maximumHeight: CGFloat = MenuBarView.maximumHeight
    ) {
        self.maximumHeight = maximumHeight
        self.store = store
        self.updates = updates
        self.showInitialConsentDashboard = showInitialConsentDashboard
        _range = State(initialValue: range)
        _showsDetails = State(initialValue: showsDetails)
    }

    var body: some View {
        let now = Date.now
        let snapshot = DashboardSnapshot(
            records: store.records,
            range: range,
            selection: store.dashboardSelection,
            activeModel: store.activeModel,
            now: now,
            clientFilter: store.clientFilter,
            providerFilter: store.providerFilter
        )
        VStack(spacing: 0) {
            header
            ScrollView {
                content(snapshot: snapshot, now: now)
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maximumHeight - Self.chromeHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            Divider().overlay(DashboardStyle.line)
            footer
        }
        .frame(width: Self.width)
        .background(DashboardStyle.surface)
        .tint(DashboardStyle.accent)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            BrandMarkView(size: 24)
            Text("Tokrate")
                .font(DashboardStyle.Typography.title).tracking(-0.3)
                .foregroundStyle(DashboardStyle.ink)
                .lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            ModelPickerMenu(store: store)
            gearMenu
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var gearMenu: some View {
        Menu {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Full history…") {
                if !showInitialConsentDashboard() {
                    openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Button(store.isMonitoring ? "Pause monitoring" : "Resume monitoring") {
                if store.isMonitoring { store.stopMonitoring() } else { store.startMonitoring() }
            }
            Toggle("Show speed in menu bar", isOn: $showMenuBarSpeed)
                .help("Shows the live response speed of the followed model. All models shows Compare without a pooled speed.")
            Toggle("Show provider badge", isOn: $showProviderBadge)
                .help("Shows a letter badge for the model's maker before the speed in the menu bar.")
            Divider()
            Link("Privacy details", destination: URL(string: "https://tokrate.dev/privacy")!)
            Button("Quit Tokrate") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15))
                .foregroundStyle(DashboardStyle.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Tokrate settings and full history")
        .help("Settings, full history and more")
    }

    // MARK: Content

    @ViewBuilder
    private func content(snapshot: DashboardSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.sharingPreferences.isConsentDisclosureVisible { consentBanner }
            if snapshot.selection.isAllModels {
                CohortComparisonView(snapshot: snapshot, range: $range, compact: true) { cohort in
                    store.dashboardSelection = .cohort(cohort)
                }
            } else {
                let reading = snapshot.heroReading(live: store.liveSpeed, liveGroup: store.liveSpeed == nil ? nil : store.menuBarReadout.group)
                ThroughputGaugeView(
                    reading: reading,
                    compact: true,
                    delta: snapshot.speedDelta(for: reading),
                    slowerThanUsual: snapshot.personalTrend?.status == .slower,
                    groupMedian: reading.usesResponseSpeed ? snapshot.responseGaugeMedian : snapshot.turnGaugeMedian,
                    now: now
                )
                separator
                TrendChartView(snapshot: snapshot, range: $range, compact: true)
                if snapshot.responseSummaries.count > 1 {
                    separator
                    yourModels(snapshot: snapshot)
                }
                if let line = communityLine(snapshot: snapshot) {
                    separator
                    CommunityLineView(line: line)
                }
            }
            separator
            details(snapshot: snapshot)
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(error)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(DashboardStyle.line).frame(height: 1).accessibilityHidden(true)
    }

    private var consentBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(DashboardStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose whether to contribute")
                    .font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                Text("Sharing stays off until you decide. Local monitoring and history work either way.")
                    .font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review and choose…") {
                    if !showInitialConsentDashboard() {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardInset(padding: 12)
    }

    private func yourModels(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Your models")
            ResponseListView(
                summaries: snapshot.responseSummaries,
                sort: .faster,
                selected: snapshot.selectedCohort,
                rowLimit: 3
            ) { cohort in
                store.dashboardSelection = .cohort(cohort)
            }
            .padding(.horizontal, -8)
        }
    }

    private func communityLine(snapshot: DashboardSnapshot) -> CommunityLine? {
        guard store.sharingPreferences.isSharingRequested,
              store.sharing.isEnabled,
              let board = store.sharing.board,
              let cohort = snapshot.selectedCohort else { return nil }
        return CommunityLine.make(board: board, cohort: cohort, local: snapshot.localPeriodComparison)
    }

    private func details(snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showsDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        .foregroundStyle(DashboardStyle.muted)
                    Text("Details").font(DashboardStyle.Typography.footnoteEmphasis).foregroundStyle(DashboardStyle.ink)
                    Text("Period comparison, community and definitions")
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details")
            .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows period comparison, community details and definitions")
            if showsDetails {
                if !snapshot.selection.isAllModels {
                    SummaryView(snapshot: snapshot, compact: true)
                    PersonalTrendView(trend: snapshot.personalTrend, reasoningEffort: snapshot.selectedCohort?.reasoningEffort, compact: true)
                }
                SharingView(
                    preferences: store.sharingPreferences,
                    selection: store.dashboardSelection,
                    resolvedCohort: store.resolvedCohort,
                    showToggle: false,
                    showConsentDisclosure: false,
                    framed: false,
                    checkForUpdates: { updates.checkForUpdates() }
                )
                .dashboardInset(padding: 10)
                definitions
            }
        }
    }

    private var definitions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How Tokrate measures speed")
                .font(DashboardStyle.Typography.footnoteEmphasis).foregroundStyle(DashboardStyle.ink)
            Text("\(ResponseSpeedCopy.explanation) Turn speed is output tokens divided by whole-turn seconds, including tools, waiting and reasoning. Speed ordering is not a quality ranking. First token is shown only when Codex reports it. Effort is read from session metadata when present; speed tier and workload are not controlled.")
                .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardInset(padding: 10)
    }

    // MARK: Footer

    private var footer: some View {
        let preferences = store.sharingPreferences
        let sharingTitle = SharingStateLabel.title(
            isRequested: preferences.isSharingRequested,
            isActive: store.sharing.isEnabled,
            isPending: preferences.isConsentDisclosureVisible
        )
        let sharingColor: Color = preferences.isConsentDisclosureVisible || !preferences.isSharingRequested
            ? DashboardStyle.muted
            : (store.sharing.isEnabled ? DashboardStyle.good : DashboardStyle.warn)
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(store.isMonitoring ? DashboardStyle.good : DashboardStyle.muted)
                    .frame(width: 8, height: 8)
                Text(store.isMonitoring ? "Monitoring" : "Paused")
                    .foregroundStyle(DashboardStyle.ink)
                Text("·").foregroundStyle(DashboardStyle.muted)
                Text(sharingTitle).foregroundStyle(sharingColor)
            }
            .font(DashboardStyle.Typography.footnoteEmphasis)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(store.isMonitoring ? "Monitoring" : "Paused"). \(sharingTitle)")
            .help(store.folderDescription)
            Spacer(minLength: 6)
            WebsiteLinkView(compact: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// "Community median 71.0 tok/s · 24 h" with your relative position and any early/older caution.
struct CommunityLineView: View {
    let line: CommunityLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "globe.americas.fill").foregroundStyle(DashboardStyle.accent)
                    .accessibilityHidden(true)
                Text("Community median").foregroundStyle(DashboardStyle.muted)
                Text(String(format: "%.1f", line.medianTPS)).font(DashboardStyle.Typography.value(size: 15)).monospacedDigit()
                    .foregroundStyle(DashboardStyle.ink)
                Text("tok/s · \(line.windowLabel)").foregroundStyle(DashboardStyle.muted)
                Spacer(minLength: 4)
                if let caution = line.caution { ChipView(text: caution.title, tone: .warn).fixedSize() }
            }
            .font(DashboardStyle.Typography.footnote)
            .lineLimit(1)
            if let text = line.positionText {
                Text(text)
                    .font(DashboardStyle.Typography.footnoteEmphasis)
                    .foregroundStyle(positionColor)
                    .padding(.leading, 22)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Community median")
        .accessibilityValue(accessibilityValue)
    }

    private var positionColor: Color {
        switch line.position {
        case .faster?: DashboardStyle.good
        case .slower?: DashboardStyle.warn
        default: DashboardStyle.muted
        }
    }

    private var accessibilityValue: String {
        var parts = [String(format: "%.1f tokens per second over %@", line.medianTPS, line.windowLabel)]
        if let text = line.positionText { parts.append(text) }
        if let caution = line.caution { parts.append(caution.title) }
        return parts.joined(separator: ", ")
    }
}
