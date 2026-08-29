import SwiftUI

struct SettingsView: View {
    @Bindable var languageSettings: AppLanguageSettings

    var body: some View {
        TabView {
            GeneralSettingsPane(languageSettings: languageSettings)
                .tabItem {
                    Label("settings.tab.general", systemImage: "gearshape")
                }

            AppearanceSettingsPane()
                .tabItem {
                    Label("settings.tab.appearance", systemImage: "paintbrush")
                }

            ShortcutsSettingsPane()
                .tabItem {
                    Label("settings.tab.shortcuts", systemImage: "command")
                }

            PrivacySettingsPane()
                .tabItem {
                    Label("settings.tab.privacy", systemImage: "hand.raised")
                }

            UpdatesSettingsPane()
                .tabItem {
                    Label("settings.tab.updates", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }

            LicenseSettingsPane()
                .tabItem {
                    Label("settings.tab.license", systemImage: "checkmark.seal")
                }
        }
        .frame(
            width: DevSpaceLayout.settingsWidth,
            height: DevSpaceLayout.settingsHeight
        )
        .environment(\.appLanguage, languageSettings.language)
        .environment(\.locale, languageSettings.language.locale)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var languageSettings: AppLanguageSettings

    var body: some View {
        SettingsPane(title: "settings.tab.general") {
            LabeledContent(
                "settings.general.product",
                value: DevSpaceProduct.workspace.displayName
            )
            LabeledContent(
                "settings.general.suite",
                value: DevSpaceBrand.name
            )
            LabeledContent("settings.general.data-source") {
                Text("settings.general.data-source.preview")
            }
            Picker(
                "settings.general.language",
                selection: $languageSettings.language
            ) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName(in: languageSettings.language))
                        .tag(language)
                }
            }

            Text("settings.general.preview-note")
                .settingsNote()
        }
    }
}

private struct AppearanceSettingsPane: View {
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        SettingsPane(title: "settings.tab.appearance") {
            LabeledContent(
                "settings.appearance.product-accent",
                value: DevSpaceProduct.workspace.accentHex
            )

            HStack(spacing: DevSpaceSpacing.small) {
                DevSpaceStatusBadge(
                    status: .ready,
                    title: appLanguage.localized("settings.appearance.ready")
                )
                DevSpaceStatusBadge(
                    status: .needsAttention,
                    title: appLanguage.localized("settings.appearance.needs-attention")
                )
            }

            Text("settings.appearance.note")
                .settingsNote()
        }
    }
}

private struct ShortcutsSettingsPane: View {
    var body: some View {
        SettingsPane(title: "settings.tab.shortcuts") {
            Label("settings.shortcuts.unavailable", systemImage: "keyboard")
            Text("settings.shortcuts.note")
                .settingsNote()
        }
    }
}

private struct PrivacySettingsPane: View {
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        SettingsPane(title: "settings.tab.privacy") {
            Label("settings.privacy.local-first", systemImage: "internaldrive")
                .font(.headline)
            Text(DevSpacePrivacyPolicy.summary(in: appLanguage))
            Text(DevSpacePrivacyPolicy.currentBuild(in: appLanguage))
                .settingsNote()
            Text("settings.privacy.ownership-note")
                .settingsNote()
        }
    }
}

private struct UpdatesSettingsPane: View {
    @Environment(\.appLanguage) private var appLanguage
    private let version = AppVersion.current()

    var body: some View {
        SettingsPane(title: "settings.tab.updates") {
            LabeledContent(
                "settings.updates.version",
                value: version.marketingVersion
            )
            LabeledContent(
                "settings.updates.build",
                value: version.buildNumber
            )
            Text(DevSpaceUpdatePolicy.summary(in: appLanguage))
            Text(DevSpaceUpdatePolicy.previewStatus(in: appLanguage))
                .settingsNote()
        }
    }
}

private struct LicenseSettingsPane: View {
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        SettingsPane(title: "settings.tab.license") {
            Label(
                "settings.license.independent-entitlement",
                systemImage: "app.badge.checkmark"
            )
                .font(.headline)
            Text(DevSpaceLicensePolicy.summary(in: appLanguage))
            Text(DevSpaceLicensePolicy.bundleRule(in: appLanguage))
                .settingsNote()
            Text(DevSpaceLicensePolicy.previewStatus(in: appLanguage))
                .settingsNote()
        }
    }
}

private struct SettingsPane<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Section(title) {
                content
            }
        }
        .formStyle(.grouped)
        .padding(.top, DevSpaceSpacing.small)
    }
}

private extension View {
    func settingsNote() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
