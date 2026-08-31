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
                    Label("workspace.action.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier("menuBar.refresh")

                Spacer()

                Button("workspace.action.open", action: openWorkspace)
                    .keyboardShortcut("o", modifiers: .command)
                    .accessibilityIdentifier("menuBar.openWorkspace")
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
