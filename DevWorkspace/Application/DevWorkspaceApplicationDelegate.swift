import AppKit

@MainActor
final class DevWorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    let languageSettings = AppLanguageSettings()
    let appearanceSettings = AppearanceSettings()
    let notificationSettings = NotificationSettings()
    let notificationManager = SystemUserNotificationManager()
    lazy var shortcutSettings = AppShortcutSettings(
        registrar: CarbonGlobalShortcutRegistrar()
    ) { [weak self] in
        self?.menuBarController?.showWorkspace()
    }

    private var menuBarController: MenuBarController?
    private var notificationCoordinator: WorkspaceNotificationCoordinator?

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
            name: "ECM API"
        )
        let store = WorkspaceStore(
            project: project,
            provider: PreviewWorkspaceSnapshotProvider()
        )
        let refreshController = WorkspaceRefreshController(store: store)

        menuBarController = MenuBarController(
            store: store,
            languageSettings: languageSettings,
            appearanceSettings: appearanceSettings,
            shortcutSettings: shortcutSettings,
            notificationSettings: notificationSettings,
            notificationManager: notificationManager,
            refreshController: refreshController
        )
        notificationCoordinator = WorkspaceNotificationCoordinator(
            store: store,
            settings: notificationSettings,
            languageSettings: languageSettings,
            manager: notificationManager
        )

        // 菜单栏本身就是状态摘要；不能等用户先打开 Popover 才开始读取状态，
        // 否则启动后会长期停留在“未加载”，与真实工作区状态不一致。
        notificationCoordinator?.start()
        menuBarController?.startMonitoring()
        Task {
            await notificationSettings.refreshAuthorization(
                using: notificationManager
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 显式取消调度任务，避免常驻轮询跨越应用生命周期或在终止期间发起新采集。
        menuBarController?.stopMonitoring()
        notificationCoordinator?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}
