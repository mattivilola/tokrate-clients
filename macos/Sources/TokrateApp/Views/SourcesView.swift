import SwiftUI
import UniformTypeIdentifiers

/// Codex session-folder chooser, shared by Settings > Sources and the full history window.
/// Choosing is only possible while monitoring is paused, as before.
struct CodexFolderButton: View {
    @Bindable var store: HistoryStore
    @State private var isChoosing = false

    var body: some View {
        Button("Choose folder…") { isChoosing = true }
            .disabled(store.isMonitoring)
            .help(store.isMonitoring ? "Pause monitoring to choose a different Codex folder." : "Choose a different Codex session folder")
            .accessibilityHint(store.isMonitoring ? "Unavailable while monitoring. Pause monitoring first." : "Opens a folder picker")
            .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { store.selectFolder(url) }
            }
    }
}

/// Detected-sources list: Codex, Claude Code and Grok Build, found or not.
struct SourceStatusList<Accessory: View>: View {
    let statuses: [SourceStatus]
    var showsPaths = true
    @ViewBuilder var accessory: (SourceStatus) -> Accessory

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                if index > 0 { Divider().overlay(DashboardStyle.line) }
                row(status)
            }
        }
    }

    private func row(_ status: SourceStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: status.isFound ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(status.isFound ? DashboardStyle.good : DashboardStyle.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.title).font(DashboardStyle.Typography.bodyEmphasis).foregroundStyle(DashboardStyle.ink)
                    Text(statusText(status)).font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.muted)
                }
                if showsPaths {
                    Text(status.path)
                        .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                        .lineLimit(1).truncationMode(.middle)
                        .help(status.path)
                }
            }
            Spacer(minLength: 8)
            accessory(status)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.title), \(status.isFound ? "found" : "not found")")
    }

    private func statusText(_ status: SourceStatus) -> String {
        let base = status.isFound ? "Found" : "Not found"
        return status.detail.map { "\(base) · \($0)" } ?? base
    }
}

extension SourceStatusList where Accessory == EmptyView {
    init(statuses: [SourceStatus], showsPaths: Bool = true) {
        self.init(statuses: statuses, showsPaths: showsPaths) { _ in EmptyView() }
    }
}
