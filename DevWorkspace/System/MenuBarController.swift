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

        button.target = self
        button.action = #selector(statusItemPressed(_:))
        if #available(macOS 27.0, *) {
            // 系统的展开会话会在隐藏菜单栏收起时结束；旧版仍使用按钮点击切换。
            statusItem.expandedInterfaceDelegate = self
            button.sendAction(on: [.rightMouseUp])
        } else {
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
                    self?.popover.performClose(nil)
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

        popover.behavior = .transient
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
            popover.performClose(nil)
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
            popover.performClose(nil)
        } else {
            showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        popover.performClose(nil)

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
    func popoverDidShow(_ notification: Notification) {
        updateRefreshVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        if #available(macOS 27.0, *) {
            // 由弹窗内操作或失焦关闭时，也要结束系统会话，避免菜单栏仍认为它展开。
            statusItem.expandedInterfaceSession?.cancel()
        }
        updateRefreshVisibility()
    }
}

@available(macOS 27.0, *)
// AppKit calls this UI delegate on the main thread, but its new protocol lacks actor isolation.
extension MenuBarController: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(
        _ statusItem: NSStatusItem,
        didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession
    ) {
        guard let button = statusItem.button else { return }
        showPopover(relativeTo: button)
    }

    func statusItemDidEndExpandedInterfaceSession(
        _ statusItem: NSStatusItem,
        animated: Bool
    ) {
        // 点击菜单栏之外或隐藏菜单栏自动收起时，系统会结束会话。
        popover.performClose(nil)
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
