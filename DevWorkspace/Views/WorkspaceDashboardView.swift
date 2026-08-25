import SwiftUI

struct WorkspaceDashboardView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.project.name)
                        .font(.largeTitle.bold())
                    Text(store.project.rootDirectory.path())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }

            WorkspaceSummaryView(state: store.state)
                .frame(maxWidth: 520, alignment: .leading)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 480)
        .task {
            if store.shouldLoad {
                await store.refresh()
            }
        }
    }
}
