import Foundation

enum DevSpaceUpdatePolicy {
    static let summary = "Each DevSpace app checks and installs updates independently."
    static let previewStatus = "Automatic update checks are not enabled in this preview build."
}

enum DevSpaceLicensePolicy {
    static let summary = "DevMeter, DevWorkspace, and DevMemory keep independent entitlements."
    static let bundleRule = "A DevSpace Bundle grants each installed app its own entitlement; it does not create a runtime dependency."
    static let previewStatus = "This preview build does not require license activation."
}

enum DevSpacePrivacyPolicy {
    static let summary = "Local First: project data remains on this Mac unless you explicitly approve a future sharing feature."
    static let currentBuild = "This preview build does not transmit project data, use tracking, or include third-party runtime SDKs."
}

struct AppVersion: Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String

    static func current(bundle: Bundle = .main) -> Self {
        Self(
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        )
    }
}
