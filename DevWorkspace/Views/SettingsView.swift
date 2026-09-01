import SwiftUI

struct SettingsView: View {
    @Bindable var languageSettings: AppLanguageSettings
    @Bindable var shortcutSettings: AppShortcutSettings
    @Bindable var appearanceSettings: AppearanceSettings

    var body: some View {
        TabView {
            GeneralSettingsPane(languageSettings: languageSettings)
                .tabItem {
                    Label("settings.tab.general", systemImage: "gearshape")
                }

            AppearanceSettingsPane(appearanceSettings: appearanceSettings)
                .tabItem {
                    Label("settings.tab.appearance", systemImage: "paintbrush")
                }

            ShortcutsSettingsPane(shortcutSettings: shortcutSettings)
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
        .preferredColorScheme(appearanceSettings.colorMode.preferredColorScheme)
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

private struct ShortcutsSettingsPane: View {
    @Environment(\.appLanguage) private var appLanguage
    @Bindable var shortcutSettings: AppShortcutSettings

    var body: some View {
        SettingsPane(title: "settings.tab.shortcuts") {
            LabeledContent("settings.shortcuts.global") {
                HStack(spacing: DevSpaceSpacing.small) {
                    GlobalShortcutRecorder(
                        shortcut: shortcutSettings.shortcut,
                        recordingPrompt: appLanguage.localized(
                            "settings.shortcuts.recording"
                        ),
                        accessibilityLabel: appLanguage.localized(
                            "settings.shortcuts.global"
                        )
                    ) { candidate in
                        shortcutSettings.apply(candidate)
                    }
                    .frame(width: 118)

                    Button("settings.shortcuts.reset") {
                        shortcutSettings.resetToDefault()
                    }
                }
            }

            shortcutStatus

            Toggle(
                "settings.shortcuts.show-menu-bar-icon",
                isOn: $shortcutSettings.isMenuBarIconVisible
            )
            .disabled(!shortcutSettings.isShortcutRegistered)

            Text("settings.shortcuts.note")
                .settingsNote()
        }
    }

    @ViewBuilder
    private var shortcutStatus: some View {
        switch shortcutSettings.registrationIssue {
        case let .conflict(shortcut):
            Label(
                String(
                    format: appLanguage.localized(
                        "settings.shortcuts.conflict-format"
                    ),
                    locale: appLanguage.locale,
                    shortcut.displayName
                ),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .systemFailure:
            Label(
                "settings.shortcuts.registration-failed",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case nil:
            Label(
                "settings.shortcuts.active",
                systemImage: "checkmark.circle"
            )
            .foregroundStyle(.secondary)
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
