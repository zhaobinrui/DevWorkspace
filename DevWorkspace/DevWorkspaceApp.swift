import SwiftUI

@main
struct DevWorkspaceApp: App {
    @State private var store: WorkspaceStore

    init() {
        let project = ProjectReference(
            name: "DevWorkspace",
            rootDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        _store = State(
            initialValue: WorkspaceStore(
                project: project,
                provider: PreviewWorkspaceSnapshotProvider()
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            let presentation = WorkspaceStatusPresentation(state: store.state)
            Label(presentation.title, systemImage: presentation.systemImage)
        }
        .menuBarExtraStyle(.window)

        Window("DevWorkspace", id: "workspace") {
            WorkspaceDashboardView(store: store)
        }

        Settings {
            SettingsView()
        }
    }
}
