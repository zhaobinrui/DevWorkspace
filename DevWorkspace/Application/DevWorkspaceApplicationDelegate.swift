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
        // Unit-test hosts create their own stores and windows; do not load the user's catalog or start polling there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let store = WorkspaceStore(
            provider: ObservedWorkspaceSnapshotProvider(),
            catalogRepository: FileProjectCatalogRepository.applicationDefault
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
        if store.project == nil { menuBarController?.showWorkspace() }
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
