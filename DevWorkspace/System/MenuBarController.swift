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
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    // 关闭窗口后继续持有控制器，既避免 AppKit 释放窗口，也保留同一 SwiftUI 状态树供再次打开。
    private var workspaceWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?

    init(
        store: WorkspaceStore,
        languageSettings: AppLanguageSettings,
        appearanceSettings: AppearanceSettings = AppearanceSettings(),
        shortcutSettings: AppShortcutSettings
    ) {
        self.store = store
        self.languageSettings = languageSettings
        self.appearanceSettings = appearanceSettings
        self.shortcutSettings = shortcutSettings
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
        // NSStatusItem 默认只处理主按钮；显式订阅右键释放，才能提供不依赖 Popover 的退出菜单。
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
                }
            )
        }
        let hostingController = NSHostingController(rootView: content)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: DevSpaceLayout.menuBarWidth,
            height: 600
        )
        popover.contentViewController = hostingController
    }

    private func observeApplicationState() {
        // withObservationTracking 的回调只通知下一次变更；变更后递归注册新的 tracking，
        // 才能持续观察 store 与语言设置，同时保证所有 AppKit 更新都留在主线程。
        withObservationTracking {
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
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .minY
            )
        }
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
                    WorkspaceDashboardView(store: store)
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
                    width: DevSpaceLayout.dashboardMinimumWidth,
                    height: DevSpaceLayout.dashboardMinimumHeight
                )
            )
            window.center()
            window.isReleasedWhenClosed = false
            workspaceWindowController = NSWindowController(window: window)
        }

        show(windowController: workspaceWindowController)
    }

    @objc
    private func showSettingsFromMenu() {
        if settingsWindowController == nil {
            let hostingController = NSHostingController(
                rootView: SettingsView(
                    languageSettings: languageSettings,
                    shortcutSettings: shortcutSettings,
                    appearanceSettings: appearanceSettings
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
}
