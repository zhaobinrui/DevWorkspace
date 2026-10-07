import AppKit
import Observation
import SwiftUI

enum MenuBarClickAction: Equatable, Sendable {
    case togglePopover
    case showContextMenu

    init(eventType: NSEvent.EventType?) {
        self = eventType == .rightMouseUp ? .showContextMenu : .togglePopover
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let store: WorkspaceStore
    private let languageSettings: AppLanguageSettings
    private let appearanceSettings: AppearanceSettings
    private let shortcutSettings: AppShortcutSettings
    private let notificationSettings: NotificationSettings
    private let notificationManager: any UserNotificationManaging
    private let refreshController: WorkspaceRefreshController
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    // 关闭窗口后继续持有控制器，既避免 AppKit 释放窗口，也保留同一 SwiftUI 状态树供再次打开。
    private var workspaceWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var isWorkspaceWindowVisible = false
    private var monitoringEnabled = false
    private var monitoredProject: ProjectReference?

    init(
        store: WorkspaceStore,
        languageSettings: AppLanguageSettings,
        appearanceSettings: AppearanceSettings = AppearanceSettings(),
        shortcutSettings: AppShortcutSettings,
        notificationSettings: NotificationSettings = NotificationSettings(),
        notificationManager: any UserNotificationManaging = SystemUserNotificationManager(),
        refreshController: WorkspaceRefreshController? = nil
    ) {
        self.store = store
        self.languageSettings = languageSettings
        self.appearanceSettings = appearanceSettings
        self.shortcutSettings = shortcutSettings
        self.notificationSettings = notificationSettings
        self.notificationManager = notificationManager
        self.refreshController = refreshController
            ?? WorkspaceRefreshController(store: store)
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
        observeApplicationState()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            preconditionFailure("A status item button is required")
        }

        if #available(macOS 27.0, *) {
            // 新版菜单栏自己管理展开与收起。按钮 action 会与展开会话争抢同一次点击，
            // 因此只用单独的右键手势保留管理菜单，不再为左键设置 action。
            statusItem.expandedInterfaceDelegate = self
            let rightClick = NSClickGestureRecognizer(
                target: self,
                action: #selector(statusItemRightClicked(_:))
            )
            rightClick.buttonMask = 0x2
            button.addGestureRecognizer(rightClick)
        } else {
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        button.imagePosition = .imageLeading
    }

    private func configurePopover() {
        let content = AppLanguageRootView(settings: languageSettings) {
            MenuBarContentView(
                store: store,
                appearanceSettings: appearanceSettings,
                openWorkspace: { [weak self] in
                    self?.closePopover()
                    self?.showWorkspace()
                },
                openProjectFolder: { [weak self] rootDirectory in
                    self?.openProjectFolder(rootDirectory)
                },
                openExternalURL: { [weak self] url in
                    self?.openExternalURL(url)
                },
                copyText: { [weak self] text in
                    self?.copyText(text)
                },
                refresh: { [weak self] in
                    await self?.refreshController.refreshNow()
                }
            )
        }
        let hostingController = NSHostingController(rootView: content)

        // macOS 27 的展开会话是弹窗生命周期的唯一来源；旧系统仍由 transient
        // popover 负责点击外部时的关闭。
        if #available(macOS 27.0, *) {
            popover.behavior = .applicationDefined
        } else {
            popover.behavior = .transient
        }
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(
            width: DevSpaceLayout.menuBarWidth,
            height: 600
        )
        popover.contentViewController = hostingController
    }

    func startMonitoring() {
        monitoringEnabled = true
        synchronizeSelectedProject()
    }

    func stopMonitoring() {
        monitoringEnabled = false
        refreshController.stop()
    }

    private func synchronizeSelectedProject() {
        guard monitoringEnabled else { return }
        let selected = store.project
        if monitoredProject != selected || !refreshController.isRunning {
            refreshController.stop()
            monitoredProject = selected
            if selected != nil { refreshController.start() }
        }
    }

    private func observeApplicationState() {
        // withObservationTracking 的回调只通知下一次变更；变更后递归注册新的 tracking，
        // 才能持续观察 store 与语言设置，同时保证所有 AppKit 更新都留在主线程。
        withObservationTracking {
            synchronizeSelectedProject()
            updateStatusItem(
                for: store.state,
                language: languageSettings.language
            )
            updateLocalizedWindowTitles(language: languageSettings.language)
            updateMenuBarVisibility(
                isVisible: shortcutSettings.effectiveMenuBarIconVisibility
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeApplicationState()
            }
        }
    }

    private func updateMenuBarVisibility(isVisible: Bool) {
        if !isVisible {
            closePopover()
        }
        statusItem.isVisible = isVisible
    }

    private func updateStatusItem(
        for state: WorkspaceStore.State,
        language: AppLanguage
    ) {
        guard let button = statusItem.button else {
            return
        }

        let presentation = MenuBarStatusPresentation(
            state: state,
            language: language
        )
        let icon = DevSpaceProduct.workspace.icon
        let image = NSImage(named: NSImage.Name(icon.menuBarAssetName))
            ?? NSImage(
                systemSymbolName: icon.fallbackSystemSymbolName,
                accessibilityDescription: presentation.title
            )
        image?.isTemplate = true
        // 模板图像由 macOS 根据菜单栏明暗和可访问性状态着色，不能保留资源自身颜色。
        image?.accessibilityDescription = presentation.title

        button.image = image
        button.title = presentation.visibleTitle
        button.imagePosition = presentation.showsTitle
            ? .imageLeading
            : .imageOnly
        button.toolTip = "\(DevSpaceProduct.workspace.displayName) — \(presentation.title)"
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc
    private func statusItemPressed(_ sender: NSStatusBarButton) {
        switch MenuBarClickAction(eventType: NSApp.currentEvent?.type) {
        case .togglePopover:
            togglePopover(relativeTo: sender)
        case .showContextMenu:
            showContextMenu(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(relativeTo: button)
        }
    }

    @objc
    private func statusItemRightClicked(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended,
              let button = statusItem.button else { return }
        showContextMenu(relativeTo: button)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        if #available(macOS 27.0, *) {
            statusItem.expandedInterfaceSession?.cancel()
        }
        popover.close()
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        closePopover()

        let menu = makeContextMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
            in: button
        )
    }

    func makeContextMenu() -> NSMenu {
        let language = languageSettings.language
        let menu = NSMenu()
        menu.addItem(
            menuItem(
                title: language.localized("menu.open-workspace"),
                action: #selector(showWorkspaceFromMenu),
                keyEquivalent: "o"
            )
        )
        menu.addItem(
            menuItem(
                title: language.localized("menu.settings"),
                action: #selector(showSettingsFromMenu),
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: String(
                    format: language.localized("menu.quit-format"),
                    locale: language.locale,
                    DevSpaceProduct.workspace.displayName
                ),
                action: #selector(terminateApplication),
                keyEquivalent: "q"
            )
        )
        return menu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = .command
        }
        return item
    }

    @objc
    private func showWorkspaceFromMenu() {
        showWorkspace()
    }

    func showWorkspace() {
        if workspaceWindowController == nil {
            let hostingController = NSHostingController(
                rootView: AppLanguageRootView(settings: languageSettings) {
                    WorkspaceDashboardView(
                        store: store,
                        refresh: { [weak self] in
                            await self?.refreshController.refreshNow()
                        },
                        addProject: { [weak self] in
                            self?.chooseProjectDirectory()
                        }
                    )
                        .preferredColorScheme(
                            appearanceSettings.colorMode.preferredColorScheme
                        )
                }
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = DevSpaceProduct.workspace.displayName
            window.styleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ]
            window.setContentSize(
                NSSize(
                    width: DevSpaceLayout.dashboardInitialWidth,
                    height: DevSpaceLayout.dashboardInitialHeight
                )
            )
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            workspaceWindowController = NSWindowController(window: window)
        }

        show(windowController: workspaceWindowController)
        isWorkspaceWindowVisible = true
        updateRefreshVisibility()
    }

    @objc
    private func showSettingsFromMenu() {
        if settingsWindowController == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(
                    languageSettings: languageSettings,
                    shortcutSettings: shortcutSettings,
                    appearanceSettings: appearanceSettings,
                    notificationSettings: notificationSettings,
                    notificationManager: notificationManager
                )
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = settingsWindowTitle(language: languageSettings.language)
            window.styleMask = [.titled, .closable]
            window.setContentSize(
                NSSize(
                    width: DevSpaceLayout.settingsWidth,
                    height: DevSpaceLayout.settingsHeight
                )
            )
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindowController = NSWindowController(window: window)
        }

        show(windowController: settingsWindowController)
    }

    private func chooseProjectDirectory() {
        guard let window = workspaceWindowController?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = languageSettings.language.localized("projects.add")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                await self.store.addProject(at: directory)
                await self.refreshController.refreshNow()
            }
        }
    }

    private func show(windowController: NSWindowController?) {
        guard let windowController, let window = windowController.window else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func updateLocalizedWindowTitles(language: AppLanguage) {
        settingsWindowController?.window?.title = settingsWindowTitle(
            language: language
        )
    }

    private func settingsWindowTitle(language: AppLanguage) -> String {
        String(
            format: language.localized("window.settings-title-format"),
            locale: language.locale,
            DevSpaceProduct.workspace.displayName
        )
    }

    private func openProjectFolder(_ rootDirectory: URL) {
        guard rootDirectory.isFileURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([rootDirectory])
    }

    private func openExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc
    private func terminateApplication() {
        NSApp.terminate(nil)
    }

    private func updateRefreshVisibility() {
        refreshController.setVisible(
            popover.isShown || isWorkspaceWindowVisible
        )
    }
}

extension MenuBarController: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        if #available(macOS 27.0, *) { return true }
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              let button = statusItem.button,
              let window = button.window else { return true }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // A transient popover may dismiss on mouse-down before the status button's
        // mouse-up action. Let that action close it, instead of immediately reopening it.
        return !frame.contains(NSEvent.mouseLocation)
    }

    func popoverDidShow(_ notification: Notification) {
        updateRefreshVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        if #available(macOS 27.0, *) {
            // 弹窗内操作主动关闭时，系统也必须结束当前菜单栏展开会话。
            statusItem.expandedInterfaceSession?.cancel()
        }
        updateRefreshVisibility()
    }
}

@available(macOS 27.0, *)
// AppKit 在主线程调用 UI delegate，但新协议尚未声明 actor 隔离。
extension MenuBarController: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(
        _ statusItem: NSStatusItem,
        didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession
    ) {
        if NSApp.currentEvent?.type == .rightMouseDown
            || NSApp.currentEvent?.type == .rightMouseUp {
            expandedInterfaceSession.cancel()
            return
        }
        guard let button = statusItem.button else {
            expandedInterfaceSession.cancel()
            return
        }
        // 系统若为第二次点击开启新会话，仍按切换动作关闭，不叠加弹窗。
        if popover.isShown {
            expandedInterfaceSession.cancel()
        } else {
            showPopover(relativeTo: button)
        }
    }

    func statusItemDidEndExpandedInterfaceSession(
        _ statusItem: NSStatusItem,
        animated: Bool
    ) {
        // 包括隐藏菜单栏收起在内，所有系统结束路径都必须移除附着的弹窗。
        popover.close()
    }
}

extension MenuBarController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === workspaceWindowController?.window else {
            return
        }
        isWorkspaceWindowVisible = true
        updateRefreshVisibility()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === workspaceWindowController?.window else {
            return
        }
        isWorkspaceWindowVisible = false
        updateRefreshVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === workspaceWindowController?.window else {
            return
        }
        isWorkspaceWindowVisible = true
        updateRefreshVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === workspaceWindowController?.window else {
            return
        }
        isWorkspaceWindowVisible = false
        updateRefreshVisibility()
    }
}
