import SwiftUI

enum DashboardStyle {
    static let blue = Color.blue
    static let teal = Color.teal
    static let gradient = LinearGradient(colors: [.blue, .cyan, .teal], startPoint: .leading, endPoint: .trailing)
}

struct DashboardCard: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

extension View {
    func dashboardCard(padding: CGFloat = 16) -> some View { modifier(DashboardCard(padding: padding)) }
}
