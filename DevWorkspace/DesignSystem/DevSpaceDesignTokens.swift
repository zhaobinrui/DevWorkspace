import SwiftUI

enum DevSpaceSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum DevSpaceCornerRadius {
    static let compact: CGFloat = 6
    static let control: CGFloat = 10
    static let panel: CGFloat = 14
}

enum DevSpaceStrokeWidth {
    static let hairline: CGFloat = 1
    static let emphasized: CGFloat = 2
}

enum DevSpaceLayout {
    static let menuBarWidth: CGFloat = 360
    static let settingsWidth: CGFloat = 560
    static let settingsHeight: CGFloat = 420
    static let dashboardMinimumWidth: CGFloat = 720
    static let dashboardMinimumHeight: CGFloat = 480
}

enum DevSpaceTypography {
    static let status = Font.headline
    static let sectionLabel = Font.caption
    static let body = Font.callout
    static let metadata = Font.caption.monospacedDigit()
}

enum DevSpaceSemanticStatus: String, Codable, CaseIterable, Sendable {
    case inactive
    case inProgress
    case ready
    case needsAttention
    case failed
    case offline

    var token: DevSpaceStatusToken {
        switch self {
        case .inactive:
            DevSpaceStatusToken(
                canonicalLabel: "Stopped",
                systemImage: "stop.circle",
                color: .secondary
            )
        case .inProgress:
            DevSpaceStatusToken(
                canonicalLabel: "Starting",
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                color: .blue
            )
        case .ready:
            DevSpaceStatusToken(
                canonicalLabel: "Ready",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .needsAttention:
            DevSpaceStatusToken(
                canonicalLabel: "Needs Attention",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        case .failed:
            DevSpaceStatusToken(
                canonicalLabel: "Failed",
                systemImage: "xmark.circle.fill",
                color: .red
            )
        case .offline:
            DevSpaceStatusToken(
                canonicalLabel: "Offline",
                systemImage: "circle.dashed",
                color: .secondary
            )
        }
    }
}

struct DevSpaceStatusToken {
    let canonicalLabel: String
    let systemImage: String
    let color: Color
}

struct DevSpaceStatusBadge: View {
    let status: DevSpaceSemanticStatus
    let title: String

    var body: some View {
        let token = status.token

        Label(title, systemImage: token.systemImage)
            .font(DevSpaceTypography.status)
            .foregroundStyle(token.color)
            .padding(.horizontal, DevSpaceSpacing.small)
            .padding(.vertical, DevSpaceSpacing.xSmall)
            .background(token.color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(token.canonicalLabel): \(title)")
    }
}
