import SwiftUI

/// Opens the public board only on a deliberate click, independent of sharing.
struct WebsiteLinkView: View {
    var compact = false

    var body: some View {
        Link(destination: URL(string: "https://tokrate.dev")!) {
            if compact {
                HStack(spacing: 3) {
                    Text("Open tokrate.dev")
                    Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                }
                .font(DashboardStyle.Typography.footnoteEmphasis)
                .foregroundStyle(DashboardStyle.accent)
            } else {
                Label("Open global stats", systemImage: "arrow.up.right.square")
                    .font(DashboardStyle.Typography.body)
                    .foregroundStyle(DashboardStyle.ink)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(DashboardStyle.surface2, in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous)
                            .strokeBorder(DashboardStyle.line, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .help("Open global stats at tokrate.dev")
        .accessibilityLabel("Open global stats")
        .accessibilityHint("Opens the public Tokrate website in your default browser")
    }
}
