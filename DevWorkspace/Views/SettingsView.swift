import SwiftUI

struct SettingsView: View {
    @Bindable var languageSettings: AppLanguageSettings
    @Bindable var shortcutSettings: AppShortcutSettings
    @Bindable var appearanceSettings: AppearanceSettings
    @Bindable var notificationSettings: NotificationSettings
    let notificationManager: any UserNotificationManaging
    var updateController: WorkspaceUpdateController? = nil

    var body: some View {
        TabView {
            GeneralSettingsPane(
                languageSettings: languageSettings,
                notificationSettings: notificationSettings,
                notificationManager: notificationManager
            )
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

            UpdatesSettingsPane(updateController: updateController)
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
    @Environment(\.appLanguage) private var appLanguage
    @Bindable var languageSettings: AppLanguageSettings
    @Bindable var notificationSettings: NotificationSettings
    let notificationManager: any UserNotificationManaging

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
                Text("settings.general.data-source.local")
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

            Text("settings.general.local-note")
                .settingsNote()

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(maxWidth: .infinity)
                .frame(height: DevSpaceStrokeWidth.hairline)
                .accessibilityHidden(true)

            Label(
                "settings.general.notifications",
                systemImage: "bell.badge"
            )
            .font(.headline)

            Toggle(
                "settings.notifications.enabled",
                isOn: Binding(
                    get: { notificationSettings.isEnabled },
                    set: { requestedValue in
                        Task {
                            await notificationSettings.setEnabled(
                                requestedValue,
                                using: notificationManager
                            )
                        }
                    }
                )
            )
            .disabled(notificationSettings.isRequestingAuthorization)

            Toggle(
                "settings.notifications.failure",
                isOn: $notificationSettings.notifyOnFailure
            )
            .disabled(!notificationSettings.isEnabled)

            Toggle(
                "settings.notifications.needs-attention",
                isOn: $notificationSettings.notifyOnNeedsAttention
            )
            .disabled(!notificationSettings.isEnabled)

            Label(
                authorizationDescription,
                systemImage: authorizationSystemImage
            )
            .settingsNote()

            Text("settings.notifications.privacy-note")
                .settingsNote()
        }
        .task {
            await notificationSettings.refreshAuthorization(
                using: notificationManager
            )
        }
    }

    private var authorizationDescription: String {
        let key = switch notificationSettings.authorizationState {
        case .notDetermined:
            "settings.notifications.authorization.not-determined"
        case .denied:
            "settings.notifications.authorization.denied"
        case .authorized:
            "settings.notifications.authorization.authorized"
        }

        return appLanguage.localized(key)
    }

    private var authorizationSystemImage: String {
        switch notificationSettings.authorizationState {
        case .notDetermined:
            "questionmark.circle"
        case .denied:
            "bell.slash"
        case .authorized:
            "checkmark.circle"
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
    let updateController: WorkspaceUpdateController?

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
            if let updateController, updateController.isConfigured {
                Button("settings.updates.check-now") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)

                Toggle(
                    "settings.updates.automatic-checks",
                    isOn: Binding(
                        get: { updateController.automaticallyChecksForUpdates },
                        set: { updateController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                Text("settings.updates.network-note")
                    .settingsNote()
            } else {
                Label(
                    "settings.updates.not-configured",
                    systemImage: "exclamationmark.triangle"
                )
                .settingsNote()
            }
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
