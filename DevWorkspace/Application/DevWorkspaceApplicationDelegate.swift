import AppKit

@MainActor
final class DevWorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    let languageSettings = AppLanguageSettings()
    lazy var shortcutSettings = AppShortcutSettings(
        registrar: CarbonGlobalShortcutRegistrar()
    ) { [weak self] in
        self?.menuBarController?.showWorkspace()
    }

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 工程骨架尚未接入 Project Profile 选择器，先用用户主目录建立一个稳定的本地预览
        // 身份；真实项目接入后应由用户明确选择的根目录替代这里。
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

        menuBarController = MenuBarController(
            store: store,
            languageSettings: languageSettings,
            shortcutSettings: shortcutSettings
        )

        // 菜单栏本身就是状态摘要；不能等用户先打开 Popover 才开始读取状态，
        // 否则启动后会长期停留在“未加载”，与真实工作区状态不一致。
        Task {
            await store.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
