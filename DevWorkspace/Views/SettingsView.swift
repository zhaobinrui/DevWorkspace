import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            AppearanceSettingsPane()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            ShortcutsSettingsPane()
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }

            PrivacySettingsPane()
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }

            UpdatesSettingsPane()
                .tabItem {
                    Label("Updates", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }

            LicenseSettingsPane()
                .tabItem {
                    Label("License", systemImage: "checkmark.seal")
                }
        }
        .frame(
            width: DevSpaceLayout.settingsWidth,
            height: DevSpaceLayout.settingsHeight
        )
    }
}

private struct GeneralSettingsPane: View {
    var body: some View {
        SettingsPane(title: "General") {
            LabeledContent("Product", value: DevSpaceProduct.workspace.displayName)
            LabeledContent("Suite", value: DevSpaceBrand.name)
            LabeledContent("Data source", value: "Framework preview")

            Text("真实 Git、端口和依赖适配器将在 DevWorkspace MVP 中逐步接入。")
                .settingsNote()
        }
    }
}

private struct AppearanceSettingsPane: View {
    var body: some View {
        SettingsPane(title: "Appearance") {
            LabeledContent("Product accent", value: DevSpaceProduct.workspace.accentHex)

            HStack(spacing: DevSpaceSpacing.small) {
                DevSpaceStatusBadge(status: .ready, title: "已就绪")
                DevSpaceStatusBadge(status: .needsAttention, title: "需要关注")
            }

            Text("DevSpace Design Token v1 使用统一间距、圆角、字体与语义状态；每款产品保留独立强调色。皮肤选择将在外观功能落地时启用。")
                .settingsNote()
        }
    }
}

private struct ShortcutsSettingsPane: View {
    var body: some View {
        SettingsPane(title: "Shortcuts") {
            Label("全局快捷键尚未启用", systemImage: "keyboard")
            Text("快捷键必须由用户明确配置，隐藏菜单栏图标后仍可呼出，并在保存前检测冲突。")
                .settingsNote()
        }
    }
}

private struct PrivacySettingsPane: View {
    var body: some View {
        SettingsPane(title: "Privacy") {
            Label("Local First", systemImage: "internaldrive")
                .font(.headline)
            Text(DevSpacePrivacyPolicy.summary)
            Text(DevSpacePrivacyPolicy.currentBuild)
                .settingsNote()
            Text("项目根目录、Git 状态、端口和依赖数据归 DevWorkspace 所有，不与其他 DevSpace App 共享数据库。")
                .settingsNote()
        }
    }
}

private struct UpdatesSettingsPane: View {
    private let version = AppVersion.current()

    var body: some View {
        SettingsPane(title: "Updates") {
            LabeledContent("Version", value: version.marketingVersion)
            LabeledContent("Build", value: version.buildNumber)
            Text(DevSpaceUpdatePolicy.summary)
            Text(DevSpaceUpdatePolicy.previewStatus)
                .settingsNote()
        }
    }
}

private struct LicenseSettingsPane: View {
    var body: some View {
        SettingsPane(title: "License") {
            Label("Independent entitlement", systemImage: "app.badge.checkmark")
                .font(.headline)
            Text(DevSpaceLicensePolicy.summary)
            Text(DevSpaceLicensePolicy.bundleRule)
                .settingsNote()
            Text(DevSpaceLicensePolicy.previewStatus)
                .settingsNote()
        }
    }
}

private struct SettingsPane<Content: View>: View {
    let title: String
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
