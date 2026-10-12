import Foundation

enum DevSpaceUpdatePolicy {
    static func summary(in language: AppLanguage) -> String {
        language.localized("policy.update.summary")
    }
}

enum DevSpaceLicensePolicy {
    static func summary(in language: AppLanguage) -> String {
        language.localized("policy.license.summary")
    }

    static func bundleRule(in language: AppLanguage) -> String {
        language.localized("policy.license.bundle-rule")
    }

    static func previewStatus(in language: AppLanguage) -> String {
        language.localized("policy.license.preview-status")
    }
}

enum DevSpacePrivacyPolicy {
    static func summary(in language: AppLanguage) -> String {
        language.localized("policy.privacy.summary")
    }

    static func currentBuild(in language: AppLanguage) -> String {
        language.localized("policy.privacy.current-build")
    }
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
