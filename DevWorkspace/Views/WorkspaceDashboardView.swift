import SwiftUI

struct WorkspaceDashboardView: View {
    @Bindable var store: WorkspaceStore
    let refresh: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DevSpaceSpacing.xLarge) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DevSpaceSpacing.xSmall) {
                    Text(store.project.name)
                        .font(.largeTitle.bold())
                    Text(store.project.rootDirectory.path())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    Label("workspace.action.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("workspace.refresh")
            }

            WorkspaceSummaryView(state: store.state)
                .frame(maxWidth: 520, alignment: .leading)

            Spacer()
        }
        .padding(DevSpaceSpacing.xLarge)
        .frame(
            minWidth: DevSpaceLayout.dashboardMinimumWidth,
            minHeight: DevSpaceLayout.dashboardMinimumHeight
        )
        .task {
            if store.shouldLoad {
                await refresh()
            }
        }
    }
}
