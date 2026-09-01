import SwiftUI

struct AppearanceSettingsPane: View {
    @Environment(\.appLanguage) private var appLanguage
    @Bindable var appearanceSettings: AppearanceSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DevSpaceSpacing.large) {
                Text("settings.appearance.preview")
                    .font(.headline)

                AppearanceMenuPreview(settings: appearanceSettings)

                Text("settings.appearance.skin")
                    .font(.headline)

                HStack(spacing: DevSpaceSpacing.medium) {
                    ForEach(MenuBarSkin.allCases) { skin in
                        skinChoice(skin)
                    }
                }

                Divider()

                appearancePicker(
                    titleKey: "settings.appearance.transparency",
                    selection: $appearanceSettings.transparency,
                    values: MenuBarTransparency.allCases,
                    label: { $0.localizationKey }
                )

                appearancePicker(
                    titleKey: "settings.appearance.glow",
                    selection: $appearanceSettings.glow,
                    values: MenuBarGlow.allCases,
                    label: { $0.localizationKey }
                )

                appearancePicker(
                    titleKey: "settings.appearance.color-mode",
                    selection: $appearanceSettings.colorMode,
                    values: AppAppearanceMode.allCases,
                    label: { $0.localizationKey }
                )

                appearancePicker(
                    titleKey: "settings.appearance.preview-background",
                    selection: $appearanceSettings.previewBackground,
                    values: AppearancePreviewBackground.allCases,
                    label: { $0.localizationKey }
                )

                Label(
                    "settings.appearance.accessibility-note",
                    systemImage: "accessibility"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DevSpaceSpacing.xLarge)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func skinChoice(_ skin: MenuBarSkin) -> some View {
        let isSelected = appearanceSettings.skin == skin
        let preferences = AppearancePreferences(
            skin: skin,
            transparency: appearanceSettings.transparency,
            glow: appearanceSettings.glow,
            colorMode: appearanceSettings.colorMode
        )

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                appearanceSettings.skin = skin
            }
        } label: {
            VStack(spacing: DevSpaceSpacing.small) {
                ZStack(alignment: .bottomTrailing) {
                    HStack(spacing: DevSpaceSpacing.xSmall) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.34))
                            .frame(width: 40, height: 5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .menuBarSurface(
                        preferences: preferences,
                        cornerRadius: DevSpaceCornerRadius.control,
                        showsElevation: false
                    )

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.headline)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 5, y: 5)
                    }
                }
                .frame(height: 58)
                .overlay {
                    RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.16),
                            lineWidth: isSelected
                                ? DevSpaceStrokeWidth.emphasized
                                : DevSpaceStrokeWidth.hairline
                        )
                }

                Text(appLanguage.localized(skin.localizationKey))
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(appLanguage.localized(skin.localizationKey)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func appearancePicker<Value: Hashable & Identifiable>(
        titleKey: LocalizedStringKey,
        selection: Binding<Value>,
        values: [Value],
        label: @escaping (Value) -> String
    ) -> some View {
        HStack(spacing: DevSpaceSpacing.large) {
            Text(titleKey)
                .frame(width: 112, alignment: .leading)

            Picker("", selection: selection) {
                ForEach(values) { value in
                    Text(appLanguage.localized(label(value)))
                        .tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

private struct AppearanceMenuPreview: View {
    @Environment(\.appLanguage) private var appLanguage
    @Bindable var settings: AppearanceSettings

    var body: some View {
        ZStack {
            previewBackground

            VStack(spacing: DevSpaceSpacing.small) {
                HStack(spacing: DevSpaceSpacing.small) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(
                            Color.accentColor,
                            in: RoundedRectangle(cornerRadius: DevSpaceCornerRadius.compact)
                        )
                    Text(DevSpaceProduct.workspace.displayName)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Label(
                        appLanguage.localized("workspace.status.ready"),
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                Divider()

                HStack(spacing: DevSpaceSpacing.small) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ECM API")
                            .font(.headline)
                        Text("main · API 7201 · PostgreSQL + Redis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                HStack(spacing: DevSpaceSpacing.small) {
                    Button(action: {}) {
                        Label("workspace.action.open-api", systemImage: "safari")
                    }
                    .buttonStyle(DevSpaceActionButtonStyle(role: .primary))

                    Button(action: {}) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(
                        DevSpaceActionButtonStyle(
                            role: .secondary,
                            fillsWidth: false
                        )
                    )

                    Button(action: {}) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(
                        DevSpaceActionButtonStyle(
                            role: .danger,
                            fillsWidth: false
                        )
                    )
                }
            }
            .padding(DevSpaceSpacing.medium)
            .frame(width: 360)
            .menuBarSurface(
                preferences: settings.preferences,
                cornerRadius: DevSpaceCornerRadius.panel
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: DevSpaceCornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DevSpaceCornerRadius.panel)
                .strokeBorder(
                    Color.primary.opacity(0.12),
                    lineWidth: DevSpaceStrokeWidth.hairline
                )
        }
    }

    private var previewBackground: some View {
        Group {
            switch settings.previewBackground {
            case .light:
                Color(nsColor: .underPageBackgroundColor)
            case .dark:
                Color(red: 0.035, green: 0.055, blue: 0.11)
            case .detailed:
                ZStack {
                    Color(red: 0.05, green: 0.12, blue: 0.24)
                    HStack(spacing: 0) {
                        Color.blue.opacity(0.22)
                        Color.purple.opacity(0.18)
                        Color.orange.opacity(0.14)
                    }
                }
            }
        }
    }
}
