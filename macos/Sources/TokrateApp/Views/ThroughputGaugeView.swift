import SwiftUI
import TokrateCore

/// The gauge spec from `docs/design-language.md`: 240 degree sweep from 150 to 30 degrees, a
/// gradient arc up to the value, a needle and hub only when a value exists, and a scale that
/// labels just 0 and the maximum.
enum GaugeScale {
    static let sweepDegrees = 240.0
    static let startDegrees = 150.0

    static let steps: [Double] = [20, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000]

    /// The "nice" ceiling of 1.25 x `maximum`: the first step that fits, at least 20. Beyond the
    /// last step it keeps rounding up in steps of 250.
    static func niceCeiling(forMaximum maximum: Double) -> Double {
        guard maximum.isFinite, maximum > 0 else { return steps[0] }
        let target = maximum * 1.25
        if let step = steps.first(where: { $0 >= target }) { return step }
        return (target / 250).rounded(.up) * 250
    }

    /// The hero scale: `max(latest value, the measurement group's largest 24 h median) x 1.25`,
    /// rounded to a nice step. Without any evidence the empty gauge shows a 0 to 100 track.
    static func ceiling(for value: Double?, groupMedian: Double? = nil) -> Double {
        let finite = [value, groupMedian].compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard let maximum = finite.max() else { return 100 }
        return niceCeiling(forMaximum: maximum)
    }

    static func progress(value: Double?, ceiling: Double) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(1, max(0, value / ceiling))
    }
}

/// The animatable dial. SwiftUI interpolates `progress` for the single eased transition.
struct GaugeDial: View, @preconcurrency Animatable {
    var progress: Double
    let hasValue: Bool
    let ceiling: Double
    let radius: CGFloat
    let strokeWidth: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// Canvas center from the top edge; leaves room for the stroke.
    var centerY: CGFloat { radius + strokeWidth / 2 + 4 }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: centerY)
            func location(_ degrees: Double, _ length: CGFloat) -> CGPoint {
                let radians = degrees * .pi / 180
                return CGPoint(x: center.x + cos(radians) * length, y: center.y + sin(radians) * length)
            }
            let start = GaugeScale.startDegrees, sweep = GaugeScale.sweepDegrees
            let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round)

            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
            context.stroke(track, with: .color(DashboardStyle.line), style: style)

            if hasValue {
                if progress > 0 {
                    var active = Path()
                    active.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep * progress), clockwise: false)
                    context.stroke(
                        active,
                        with: .linearGradient(
                            Gradient(colors: [DashboardStyle.arcStart, DashboardStyle.arcEnd]),
                            startPoint: CGPoint(x: center.x - radius, y: center.y),
                            endPoint: CGPoint(x: center.x + radius, y: center.y)
                        ),
                        style: style
                    )
                }
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: location(start + sweep * progress, max(0, radius - 14)))
                context.stroke(needle, with: .color(DashboardStyle.needle), style: StrokeStyle(lineWidth: max(2.5, strokeWidth * 0.3), lineCap: .round))
                let hub = max(3.5, strokeWidth * 0.36)
                context.fill(Path(ellipseIn: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)), with: .color(DashboardStyle.needle))
            }

            // Scale: label only 0 and the maximum, beside the arc ends.
            let inset = radius * 0.866 + strokeWidth / 2 + 15
            let labelY = center.y + radius * 0.5
            context.draw(
                Text("0").font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted),
                at: CGPoint(x: center.x - inset, y: labelY)
            )
            context.draw(
                Text(ceiling.formatted(.number.precision(.fractionLength(0)))).font(DashboardStyle.Typography.caption).foregroundStyle(DashboardStyle.muted),
                at: CGPoint(x: center.x + inset, y: labelY)
            )
        }
        .accessibilityHidden(true)
    }
}

/// Dial plus the readout centred below the hub: a large tabular number and `tok/s` beneath it.
struct GaugeInstrument: View {
    let value: Double?
    var compact = true
    /// Name of the measurement for accessibility ("Response speed", "Turn speed").
    var title = ResponseSpeedCopy.title
    /// Qualifier shown after the unit, such as "while responding, tools excluded".
    var qualifier: String?
    /// The largest 24 h median in the value's measurement group; stretches the scale, never other groups.
    var groupMedian: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var radius: CGFloat { compact ? 66 : 100 }
    private var stroke: CGFloat { compact ? 9 : 13 }
    private var numberSize: CGFloat { compact ? 46 : 60 }
    private var finiteValue: Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    private var ceiling: Double { GaugeScale.ceiling(for: finiteValue, groupMedian: groupMedian) }
    private var centerY: CGFloat { radius + stroke / 2 + 4 }
    /// The readout lives fully in the open lower segment, below the lowest point of the needle and arc ends.
    private var readoutTop: CGFloat { centerY + radius * 0.5 + 4 }
    private var numberHeight: CGFloat { numberSize * 1.1 }
    private var height: CGFloat { readoutTop + numberHeight + 18 }

    var body: some View {
        ZStack(alignment: .top) {
            GaugeDial(
                progress: GaugeScale.progress(value: finiteValue, ceiling: ceiling),
                hasValue: finiteValue != nil,
                ceiling: ceiling,
                radius: radius,
                strokeWidth: stroke
            )
            VStack(spacing: 0) {
                Text(DashboardSnapshot.rate(finiteValue))
                    .font(DashboardStyle.Typography.readout(size: numberSize))
                    .tracking(-1)
                    .monospacedDigit()
                    .foregroundStyle(finiteValue == nil ? DashboardStyle.muted : DashboardStyle.ink)
                    .contentTransition(.numericText(value: finiteValue ?? 0))
                    .lineLimit(1)
                    .frame(height: numberHeight)
                Text(qualifier.map { "tok/s · \($0)" } ?? "tok/s")
                    .font(DashboardStyle.Typography.footnote)
                    .foregroundStyle(DashboardStyle.muted)
                    .lineLimit(1)
            }
            .padding(.top, readoutTop)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: finiteValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(finiteValue.map { String(format: "%.1f output tokens per second", $0) } ?? "No measurement yet")
    }
}

/// The hero gauge. Response speed is primary: the live median of the latest responses, else the
/// selected model's latest turn with response data. A source without per-response timing shows its
/// latest whole-turn speed, labelled as turn speed. Never an instantaneous streaming estimate.
/// Presentation-only: it reads no store, logs, Keychain or network.
struct ThroughputGaugeView: View {
    let reading: HeroReading
    var compact = true
    /// Change against the selected model's 24 h median, when there is enough history.
    var delta: SpeedDelta?
    var slowerThanUsual = false
    /// Largest 24 h median among the reading's measurement group, for the scale.
    var groupMedian: Double?
    var now: Date = .now

    private var measurementTitle: String {
        reading.usesResponseSpeed || reading.kind == .empty ? ResponseSpeedCopy.title : (reading.cohort?.measurement.title ?? "Turn speed")
    }
    private var qualifier: String {
        reading.usesResponseSpeed || reading.kind == .empty ? ResponseSpeedCopy.shortDefinition : (reading.cohort?.measurement.shortDefinition ?? "whole turn")
    }
    private var definition: String {
        reading.usesResponseSpeed || reading.kind == .empty ? ResponseSpeedCopy.definition : (reading.cohort?.measurement.definition ?? "")
    }

    var body: some View {
        if compact {
            content
        } else {
            content.dashboardCard(padding: 18)
        }
    }

    private var content: some View {
        VStack(spacing: compact ? 8 : 12) {
            if !compact { header }
            GaugeInstrument(value: reading.value, compact: compact, title: measurementTitle, qualifier: compact ? qualifier : nil, groupMedian: groupMedian)
            meta
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(measurementTitle)
                .font(DashboardStyle.Typography.footnoteEmphasis)
                .foregroundStyle(DashboardStyle.muted)
                .lineLimit(2)
            Spacer()
            if let completedAt = reading.completedAt {
                Text(completedAt.formatted(date: .omitted, time: .shortened))
                    .font(DashboardStyle.Typography.caption.monospacedDigit())
                    .foregroundStyle(DashboardStyle.muted)
                    .help("Completed \(RelativeTime.exact(completedAt))")
            }
        }
    }

    @ViewBuilder
    private var meta: some View {
        if reading.kind != .empty, let cohort = reading.cohort {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    ProviderBadgeView(maker: ModelMaker(model: reading.model, provider: reading.provider), size: 16)
                    Text(reading.model ?? "Model not reported")
                        .font(DashboardStyle.Typography.bodyEmphasis)
                        .foregroundStyle(DashboardStyle.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if let effort = reading.effort { ChipView(text: effort).fixedSize() }
                    if let chip = reading.chip { ChipView(text: chip, tone: .accent).fixedSize() }
                }
                deltaLine
                captionLine
                if slowerThanUsual {
                    Label(reading.usesResponseSpeed ? "Your recent responses are slower than usual" : "Your recent turns are slower than usual", systemImage: "exclamationmark.circle.fill")
                        .font(DashboardStyle.Typography.footnoteEmphasis)
                        .foregroundStyle(DashboardStyle.warn)
                        .help("A personal speed trend only; it does not measure answer quality or confirm provider health.")
                }
                if !compact {
                    Text(cohort.detailLabel)
                        .font(DashboardStyle.Typography.caption)
                        .foregroundStyle(DashboardStyle.muted)
                        .lineLimit(2).multilineTextAlignment(.center)
                    Text(definition)
                        .font(DashboardStyle.Typography.caption)
                        .foregroundStyle(DashboardStyle.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .help(isGrokBuildResponse ? ResponseSpeedCopy.grokBuildExplanation : reading.usesResponseSpeed ? ResponseSpeedCopy.explanation : "\(measurementTitle) is output tokens divided by whole-turn seconds. It is not streaming speed.")
        } else {
            Text("Waiting for a completed response")
                .font(DashboardStyle.Typography.footnote)
                .foregroundStyle(DashboardStyle.muted)
        }
    }

    private var deltaLine: some View {
        let medianName = reading.usesResponseSpeed ? "response-speed median" : "median"
        return HStack(spacing: 4) {
            if let delta {
                Image(systemName: delta.isFaster ? "arrow.up.right" : delta.isSlower ? "arrow.down.right" : "equal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint(for: delta))
                    .accessibilityHidden(true)
                Text(delta.summary(medianName: medianName)).foregroundStyle(tint(for: delta))
            } else {
                Text("Collecting your 24 h baseline").foregroundStyle(DashboardStyle.muted)
            }
        }
        .font(DashboardStyle.Typography.footnote.monospacedDigit())
        .lineLimit(1).minimumScaleFactor(0.9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.usesResponseSpeed ? "Response speed change" : "Turn speed change")
        .accessibilityValue(delta?.accessibilitySummary ?? "Collecting your 24 hour baseline")
    }

    @ViewBuilder
    private var captionLine: some View {
        if let caption = reading.caption(now: now) {
            Text(caption)
                .font(DashboardStyle.Typography.footnote.monospacedDigit())
                .foregroundStyle(DashboardStyle.muted)
                .lineLimit(1)
                .help(reading.completedAt.map { "Completed \(RelativeTime.exact($0))" } ?? "")
        }
        if isGrokBuildResponse {
            Text(ResponseSpeedCopy.grokBuildNote)
                .font(DashboardStyle.Typography.caption)
                .foregroundStyle(DashboardStyle.muted)
                .lineLimit(2).multilineTextAlignment(.center)
        }
    }

    private var isGrokBuildResponse: Bool {
        reading.usesResponseSpeed && reading.cohort?.client == ResponseSpeedCopy.grokBuildClient
    }

    private func tint(for delta: SpeedDelta) -> Color {
        delta.isFaster ? DashboardStyle.good : delta.isSlower ? DashboardStyle.warn : DashboardStyle.muted
    }
}
