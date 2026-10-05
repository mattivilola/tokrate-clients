import SwiftUI
import TokrateCore

/// The affirmative-consent notice, shared by onboarding, Settings and the full history window.
/// Consent semantics live in `SharingPreferences`; this view only presents the notice and calls
/// `consentToShare()` or `chooseLocalOnly()`.
struct ConsentDisclosureView: View {
    let preferences: SharingPreferences
    var spacious = false
    /// Called after either choice has been recorded.
    var onDecision: (() -> Void)?
    @State private var showsPayload = false

    private var primaryFont: Font { spacious ? DashboardStyle.Typography.body : DashboardStyle.Typography.footnote }
    private var secondaryFont: Font { spacious ? DashboardStyle.Typography.footnote : DashboardStyle.Typography.caption }

    var body: some View {
        VStack(alignment: .leading, spacing: spacious ? 12 : 9) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").font(.system(size: spacious ? 26 : 19)).foregroundStyle(DashboardStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose whether to contribute")
                        .font(spacious ? DashboardStyle.Typography.title : DashboardStyle.Typography.footnoteEmphasis)
                        .foregroundStyle(DashboardStyle.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Local monitoring and history work either way.")
                        .font(secondaryFont).foregroundStyle(DashboardStyle.muted)
                }
            }
            Text("Tokrate sends eligible completed-turn measurements to its community service: a rounded 5-minute time, client and app/parser/metric versions, model, provider (and, for Claude on Amazon Bedrock, its inference-profile region), reasoning effort, source kind, token counts, turn duration, response-speed totals, and TTFT when available.")
                .font(primaryFont).foregroundStyle(DashboardStyle.ink).fixedSize(horizontal: false, vertical: true)
            Text("From 0.1.14 the server derives your continent from the connection's country when a sample arrives (via Cloudflare). Only the continent is stored, never the country or your IP address, and a region is shown publicly only when at least 3 contributors report from it.")
                .font(secondaryFont).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
            Text("Uploads contain no names, prompts, responses, code, or local session IDs. Each sample has a random ID and uploads use a stable public-key pseudonym, so records can be linked over time.")
                .font(secondaryFont).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
            Text("Early community data may include aggregates based on a single install.")
                .font(secondaryFont).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
            Text("You can turn sharing off any time. Tokrate stops new contributions and cancels unsent samples; local monitoring continues, and measurements already sent may remain in community data.")
                .font(secondaryFont).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
            payloadDisclosure
            HStack(spacing: 12) {
                Button("Yes, let's contribute") {
                    preferences.consentToShare()
                    onDecision?()
                }
                .buttonStyle(ConsentChoiceButtonStyle())
                .accessibilityHint("Starts sharing new turn measurements with the community")
                Button("Only for local use") {
                    preferences.chooseLocalOnly()
                    onDecision?()
                }
                .buttonStyle(ConsentChoiceButtonStyle())
                .accessibilityHint("Keeps every measurement on this Mac")
            }
            .padding(.top, 2)
            ConsentLinks()
        }
    }

    private var payloadDisclosure: some View {
        DisclosureGroup(isExpanded: $showsPayload) {
            VStack(alignment: .leading, spacing: 6) {
                Text("An example upload with made-up values. Real uploads contain these same fields and nothing else. Region is derived by the server, not sent by the app.")
                    .font(secondaryFont).foregroundStyle(DashboardStyle.muted).fixedSize(horizontal: false, vertical: true)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(SamplePayload.exampleJSON())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DashboardStyle.ink)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(DashboardStyle.surface2, in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
                .frame(maxHeight: spacious ? 230 : 160)
            }
            .padding(.top, 6)
        } label: {
            Text("See exactly what is sent")
                .font(DashboardStyle.Typography.footnoteEmphasis)
                .foregroundStyle(DashboardStyle.accent)
        }
        .tint(DashboardStyle.accent)
    }
}

/// Privacy and Terms links shown with every sharing notice.
struct ConsentLinks: View {
    var body: some View {
        HStack(spacing: 12) {
            Link("Privacy", destination: URL(string: "https://tokrate.dev/privacy")!)
            Link("Terms", destination: URL(string: "https://tokrate.dev/terms")!)
        }
        .font(DashboardStyle.Typography.caption)
        .foregroundStyle(DashboardStyle.accent)
    }
}
