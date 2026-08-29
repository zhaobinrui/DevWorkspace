import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        let key = switch self {
        case .english:
            "language.name.english"
        case .simplifiedChinese:
            "language.name.simplified-chinese"
        }

        return interfaceLanguage.localized(key)
    }

    func localized(_ key: String, bundle: Bundle = .main) -> String {
        guard
            let localizationPath = bundle.path(
                forResource: rawValue,
                ofType: "lproj"
            ),
            let localizationBundle = Bundle(path: localizationPath)
        else {
            return bundle.localizedString(
                forKey: key,
                value: key,
                table: nil
            )
        }

        return localizationBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    static func preferred(
        from preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        guard let preferredLanguage = preferredLanguages.first else {
            return .english
        }

        return preferredLanguage.lowercased().hasPrefix("zh")
            ? .simplifiedChinese
            : .english
    }
}

@MainActor
@Observable
final class AppLanguageSettings {
    static let userDefaultsKey = "app.language"

    var language: AppLanguage {
        didSet {
            guard language != oldValue else {
                return
            }

            userDefaults.set(language.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    private let userDefaults: UserDefaults

    init(
        userDefaults: UserDefaults = .standard,
        defaultLanguage: AppLanguage = .preferred()
    ) {
        self.userDefaults = userDefaults
        language = userDefaults.string(forKey: Self.userDefaultsKey)
            .flatMap(AppLanguage.init(rawValue:))
            ?? defaultLanguage
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.english
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

struct AppLanguageRootView<Content: View>: View {
    @Bindable var settings: AppLanguageSettings
    let content: Content

    init(
        settings: AppLanguageSettings,
        @ViewBuilder content: () -> Content
    ) {
        self.settings = settings
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.appLanguage, settings.language)
            .environment(\.locale, settings.language.locale)
    }
}
