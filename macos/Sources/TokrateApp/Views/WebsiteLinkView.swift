import SwiftUI

/// Opens the public board only on a deliberate click, independent of sharing.
struct WebsiteLinkView: View {
    var compact = false

    var body: some View {
        Link(destination: URL(string: "https://tokrate.dev")!) {
            if compact {
                Image(systemName: "globe")
                    .font(.system(size: 15))
                    .accessibilityLabel("Open global stats")
            } else {
                Label("Open global stats", systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.medium))
            }
        }
        .buttonStyle(.bordered)
        .help("Open global stats at tokrate.dev")
        .accessibilityHint("Opens the public Tokrate website in your default browser")
    }
}
