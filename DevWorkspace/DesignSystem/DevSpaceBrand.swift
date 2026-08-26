import Foundation

enum DevSpaceBrand {
    static let name = "DevSpace"
    static let descriptor = "Developer Desktop Suite"
    static let bundleIdentifierPrefix = "com.zhaobinrui.devspace"
}

enum DevSpaceProduct: String, CaseIterable, Codable, Sendable {
    case meter
    case workspace
    case memory

    var displayName: String {
        switch self {
        case .meter:
            "DevMeter"
        case .workspace:
            "DevWorkspace"
        case .memory:
            "DevMemory"
        }
    }

    var descriptor: String {
        switch self {
        case .meter:
            "AI usage and agent status"
        case .workspace:
            "Local project status and workspace control"
        case .memory:
            "Temporary developer memory"
        }
    }

    var bundleIdentifier: String {
        "\(DevSpaceBrand.bundleIdentifierPrefix).\(rawValue)"
    }

    var urlScheme: String {
        displayName.lowercased()
    }

    var accentHex: String {
        switch self {
        case .meter:
            "#20AEEF"
        case .workspace:
            "#6C7CEE"
        case .memory:
            "#E89A32"
        }
    }

    var icon: DevSpaceIconContract {
        switch self {
        case .meter:
            DevSpaceIconContract(
                foregroundRole: "gauge and activity pulse",
                menuBarSymbolName: "gauge.with.dots.needle.50percent"
            )
        case .workspace:
            DevSpaceIconContract(
                foregroundRole: "workspace grid and active node",
                menuBarSymbolName: "rectangle.3.group"
            )
        case .memory:
            DevSpaceIconContract(
                foregroundRole: "memory card and capture mark",
                menuBarSymbolName: "text.badge.plus"
            )
        }
    }
}

struct DevSpaceIconContract: Equatable, Sendable {
    let foregroundRole: String
    let menuBarSymbolName: String
}
