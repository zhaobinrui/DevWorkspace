import SwiftUI

@main
struct DevWorkspaceApp: App {
    @State private var store: WorkspaceStore

    init() {
        let rootDirectory = FileManager.default.homeDirectoryForCurrentUser
        let identity: ProjectIdentity

        do {
            identity = try LocalProjectIdentityResolver().resolve(rootDirectory: rootDirectory)
        } catch {
            preconditionFailure("The preview project root must be a valid local directory: \(error)")
        }

        let project = ProjectReference(identity: identity, name: DevSpaceProduct.workspace.displayName)
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
            Label(
                presentation.title,
                systemImage: DevSpaceProduct.workspace.icon.menuBarSymbolName
            )
        }
        .menuBarExtraStyle(.window)

        Window(DevSpaceProduct.workspace.displayName, id: "workspace") {
            WorkspaceDashboardView(store: store)
        }

        Settings {
            SettingsView()
        }
    }
}
