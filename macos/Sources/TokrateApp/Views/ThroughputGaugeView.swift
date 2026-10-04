import SwiftUI
import TokrateCore

/// A static dial representing an actual completed turn, never an instantaneous streaming estimate.
struct ThroughputGaugeView: View {
    let metric: TurnMetric?
    var compact = true
    private var value: Double? { metric.map(\.turnThroughputTPS).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    private var ceiling: Double { max(100, ceil((value ?? 0) / 50) * 50) }
    private var progress: Double { min(1, max(0, (value ?? 0) / ceiling)) }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(metric?.throughputLabel ?? "Turn throughput")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Spacer()
                if let metric {
                    Text(metric.completedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                dial
                VStack(spacing: 0) {
                    Text(DashboardSnapshot.rate(value))
                        .font(.system(size: compact ? 48 : 58, weight: .medium, design: .rounded))
                        .tracking(-1.5)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    Text("tokens / second")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 2)
            }
            .frame(height: compact ? 172 : 205)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metric?.throughputLabel ?? "Latest turn throughput")
            .accessibilityValue(value.map { String(format: "%.1f output tokens per whole-turn second", $0) } ?? "No completed turns yet")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(metric == nil ? Color.secondary : DashboardStyle.teal).frame(width: 5, height: 5)
                    Text(metric?.model ?? (metric == nil ? "Waiting for a completed turn" : "Model not reported"))
                        .lineLimit(1).truncationMode(.middle)
                }
                if let metric {
                    Text(ModelCohort(metric).detailLabel)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.top, 8)
            Text(metric?.metricVersion == "grok-observed-work-turn-v1"
                ? "Includes nested subagent output, tools & waiting"
                : "Includes tools, waiting & reasoning")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .dashboardCard(padding: 12)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [.blue.opacity(0.085), .teal.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var dial: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height * 0.59)
            let radius = min(size.width * 0.34, size.height * 0.53)
            let start = 140.0, sweep = 260.0
            func location(_ degrees: Double, _ length: Double) -> CGPoint {
                let radians = degrees * .pi / 180
                return CGPoint(x: center.x + cos(radians) * length, y: center.y + sin(radians) * length)
            }
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
            context.stroke(track, with: .color(.secondary.opacity(0.12)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            if value != nil {
                var active = Path()
                active.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(start + sweep * progress), clockwise: false)
                context.stroke(active, with: .linearGradient(Gradient(colors: [.blue, .cyan, .teal]), startPoint: CGPoint(x: center.x - radius, y: center.y), endPoint: CGPoint(x: center.x + radius, y: center.y)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            }
            for index in 0...20 {
                let angle = start + sweep * Double(index) / 20
                var tick = Path()
                tick.move(to: location(angle, radius - 13))
                tick.addLine(to: location(angle, radius - (index.isMultiple(of: 5) ? 23 : 18)))
                context.stroke(tick, with: .color(.secondary.opacity(index.isMultiple(of: 5) ? 0.5 : 0.25)), lineWidth: 1.25)
            }
            if value != nil {
                var needle = Path()
                needle.move(to: location(start + sweep * progress + 180, 9))
                needle.addLine(to: location(start + sweep * progress, radius - 30))
                context.stroke(needle, with: .color(.teal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(.teal))
            }
            let zero = location(start, radius + 19), maximum = location(start + sweep, radius + 19)
            context.draw(Text("0").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: zero.x, y: min(zero.y, size.height - 8)))
            context.draw(Text(ceiling.formatted(.number.precision(.fractionLength(0)))).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary), at: CGPoint(x: maximum.x, y: min(maximum.y, size.height - 8)))
        }
        .accessibilityHidden(true)
    }
}
