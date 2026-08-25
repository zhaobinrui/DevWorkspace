import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Data source", value: "Framework preview")
                Text("真实 Git、端口和依赖适配器将在 DevWorkspace MVP 中逐步接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 220)
    }
}
