import AppKit

@MainActor
final class DevWorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rootDirectory = FileManager.default.homeDirectoryForCurrentUser
        let identity: ProjectIdentity

        do {
            identity = try LocalProjectIdentityResolver().resolve(
                rootDirectory: rootDirectory
            )
        } catch {
            preconditionFailure(
                "The preview project root must be a valid local directory: \(error)"
            )
        }

        let project = ProjectReference(
            identity: identity,
            name: DevSpaceProduct.workspace.displayName
        )
        let store = WorkspaceStore(
            project: project,
            provider: PreviewWorkspaceSnapshotProvider()
        )

        menuBarController = MenuBarController(store: store)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
