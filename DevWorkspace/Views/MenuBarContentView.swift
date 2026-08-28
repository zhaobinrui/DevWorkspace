import SwiftUI

struct MenuBarContentView: View {
    @Bindable var store: WorkspaceStore
    let openWorkspace: @MainActor () -> Void

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

                Button("打开工作区", action: openWorkspace)
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
