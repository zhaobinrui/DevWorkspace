import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: DevSpaceSpacing.medium) {
            VStack(alignment: .leading, spacing: DevSpaceSpacing.xSmall) {
                Text(store.project.name)
                    .font(.headline)
                Text(store.project.rootDirectory.path())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()
            WorkspaceSummaryView(state: store.state)
            Divider()

            HStack {
                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)

                Spacer()

                Button("打开工作区") {
                    openWindow(id: "workspace")
                }
            }
        }
        .padding(DevSpaceSpacing.large)
        .frame(width: DevSpaceLayout.menuBarWidth)
        .task {
            if store.shouldLoad {
                await store.refresh()
            }
        }
    }
}
