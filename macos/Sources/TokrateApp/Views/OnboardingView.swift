import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, sharing, menuBar
}

/// First-launch flow: Welcome with detected sources, the sharing choice, then where to find Tokrate.
/// Closing the window before choosing leaves sharing off and the notice pending.
struct OnboardingView: View {
    @Bindable var store: HistoryStore
    @State var step: OnboardingStep = .welcome
    var onFinish: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 540, height: 500)

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .sharing: sharing
                case .menuBar: menuBar
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: step == .menuBar ? .center : .top)
            .transition(.opacity)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(DashboardStyle.bg)
        .tint(DashboardStyle.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
    }

    // MARK: Step 1

    private var welcome: some View {
        VStack(spacing: 18) {
            BrandMarkView(size: 72)
                .shadow(color: Color(hex: 0x0B2530).opacity(0.25), radius: 14, y: 6)
            VStack(spacing: 8) {
                Text("Welcome to Tokrate")
                    .font(.system(size: 28, weight: .semibold)).tracking(-0.4)
                    .foregroundStyle(DashboardStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("See how fast your coding model is right now, and which one is fastest.")
                    .font(DashboardStyle.Typography.title.weight(.regular)).foregroundStyle(DashboardStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Coding tools on this Mac")
                SourceStatusList(statuses: store.sourceStatuses, showsPaths: false)
                    .padding(.horizontal, 14).padding(.vertical, 2)
                    .background(DashboardStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DashboardStyle.line, lineWidth: 1) }
                Text("Tokrate reads timing and token counts from their session files, on this Mac only. Prompts, responses and code are never retained.")
                    .font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }

    // MARK: Step 2

    private var sharing: some View {
        ScrollView {
            ConsentDisclosureView(preferences: store.sharingPreferences, spacious: true) {
                step = .menuBar
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Step 3

    private var menuBar: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Find Tokrate in your menu bar")
                    .font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                    .foregroundStyle(DashboardStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Your latest turn speed lives next to the clock. Click it for the full picture.")
                    .font(DashboardStyle.Typography.title.weight(.regular)).foregroundStyle(DashboardStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            menuBarIllustration
            VStack(alignment: .leading, spacing: 10) {
                tip("gearshape", "The gear menu holds Settings, full history, and pause or resume.")
                tip("hand.raised", store.sharingPreferences.isSharingRequested
                    ? "Sharing is on. You can turn it off any time in Settings."
                    : "Sharing is off. Your measurements stay on this Mac.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(DashboardStyle.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DashboardStyle.line, lineWidth: 1) }
        }
        .padding(.top, 6)
    }

    private var menuBarIllustration: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "wifi").foregroundStyle(DashboardStyle.muted)
            Image(systemName: "battery.75percent").foregroundStyle(DashboardStyle.muted)
            HStack(spacing: 4) {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                Text("— tok/s").monospacedDigit()
            }
            .foregroundStyle(DashboardStyle.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(DashboardStyle.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DashboardStyle.accent, lineWidth: 1.5) }
            Text("9:41").font(.system(size: 13, weight: .medium)).foregroundStyle(DashboardStyle.ink)
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 14).frame(height: 34)
        .background(DashboardStyle.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DashboardStyle.line, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration of the macOS menu bar with the Tokrate speed readout beside the clock")
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(DashboardStyle.accent).frame(width: 18)
                .accessibilityHidden(true)
            Text(text).font(DashboardStyle.Typography.footnote).foregroundStyle(DashboardStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                .buttonStyle(SecondaryButtonStyle())
                .opacity(step == .sharing ? 1 : 0)
                .disabled(step != .sharing)
                .accessibilityHidden(step != .sharing)
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                    Circle().fill(item == step ? DashboardStyle.accent : DashboardStyle.line).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
            Spacer()
            Group {
                switch step {
                case .welcome: Button("Continue") { step = .sharing }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                case .sharing: Color.clear.frame(width: 60, height: 1)
                case .menuBar: Button("Done") { onFinish() }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(.top, 16)
    }
}
