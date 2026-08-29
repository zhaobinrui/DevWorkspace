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
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    private var workspaceWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?

    init(
        store: WorkspaceStore,
        languageSettings: AppLanguageSettings
    ) {
        self.store = store
        self.languageSettings = languageSettings
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
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
    }

    private func configurePopover() {
        let content = AppLanguageRootView(settings: languageSettings) {
            MenuBarContentView(
                store: store,
                openWorkspace: { [weak self] in
                    self?.showWorkspace()
                }
            )
        }
        let hostingController = NSHostingController(rootView: content)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(
            width: DevSpaceLayout.menuBarWidth,
            height: 300
        )
        popover.contentViewController = hostingController
    }

    private func observeApplicationState() {
        withObservationTracking {
            updateStatusItem(
                for: store.state,
                language: languageSettings.language
            )
            updateLocalizedWindowTitles(language: languageSettings.language)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeApplicationState()
            }
        }
    }

    private func updateStatusItem(
        for state: WorkspaceStore.State,
        language: AppLanguage
    ) {
        guard let button = statusItem.button else {
            return
        }

        let presentation = WorkspaceStatusPresentation(
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
        image?.accessibilityDescription = presentation.title

        button.image = image
        button.title = presentation.title
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
                action: #selector(showWorkspaceFromMenu)
            )
        )
        menu.addItem(
            menuItem(
                title: language.localized("menu.settings"),
                action: #selector(showSettingsFromMenu)
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
        return item
    }

    @objc
    private func showWorkspaceFromMenu() {
        showWorkspace()
    }

    private func showWorkspace() {
        if workspaceWindowController == nil {
            let hostingController = NSHostingController(
                rootView: AppLanguageRootView(settings: languageSettings) {
                    WorkspaceDashboardView(store: store)
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
                rootView: SettingsView(languageSettings: languageSettings)
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

    @objc
    private func terminateApplication() {
        NSApp.terminate(nil)
    }
}
