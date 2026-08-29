import AppKit
import Foundation
import XCTest
@testable import DevWorkspace

final class SharedFoundationTests: XCTestCase {
    private let resolver = LocalProjectIdentityResolver()

    func test_brandContract_whenProductsAreEnumerated_shouldUseUniqueNamesAndIdentifiers() {
        let products = DevSpaceProduct.allCases

        XCTAssertEqual(Set(products.map(\.displayName)).count, products.count)
        XCTAssertEqual(Set(products.map(\.bundleIdentifier)).count, products.count)
        XCTAssertEqual(Set(products.map(\.urlScheme)).count, products.count)
        XCTAssertEqual(
            Set(products.map(\.icon.menuBarAssetName)).count,
            products.count
        )
        XCTAssertTrue(products.allSatisfy { $0.bundleIdentifier.hasPrefix("com.zhaobinrui.devspace.") })
        XCTAssertTrue(products.allSatisfy { !$0.icon.menuBarAssetName.isEmpty })
        XCTAssertTrue(products.allSatisfy { !$0.icon.fallbackSystemSymbolName.isEmpty })
    }

    func test_resolve_whenCanonicalRootSpellingChanges_shouldKeepIdentifierStable() throws {
        let first = try resolver.resolve(
            rootDirectory: URL(fileURLWithPath: "/private/tmp/devspace-project", isDirectory: true)
        )
        let second = try resolver.resolve(
            rootDirectory: URL(
                fileURLWithPath: "/private/tmp/ignored/../devspace-project/",
                isDirectory: true
            )
        )

        XCTAssertEqual(first.identifier, second.identifier)
        XCTAssertEqual(first.relationship(to: second), .sameProject)
    }

    func test_resolve_whenDeclaredMetadataMoves_shouldKeepIdentifierAndRequireConfirmation() throws {
        let declaredID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let original = try resolver.resolve(
            rootDirectory: URL(fileURLWithPath: "/private/tmp/original", isDirectory: true),
            declaredMetadataID: declaredID
        )
        let moved = try resolver.resolve(
            rootDirectory: URL(fileURLWithPath: "/private/tmp/moved", isDirectory: true),
            declaredMetadataID: declaredID
        )

        XCTAssertEqual(original.identifier, moved.identifier)
        XCTAssertEqual(original.source, .declaredMetadata)
        XCTAssertEqual(original.relationship(to: moved), .requiresUserResolution)

        let corrected = try original.acceptingRootDirectory(moved.canonicalRootDirectory)
        XCTAssertEqual(corrected.relationship(to: moved), .sameProject)
    }

    func test_resolve_whenRootsDifferWithoutSharedMetadata_shouldProduceDistinctIdentifiers() throws {
        let first = try resolver.resolve(
            rootDirectory: URL(fileURLWithPath: "/private/tmp/project-a", isDirectory: true)
        )
        let second = try resolver.resolve(
            rootDirectory: URL(fileURLWithPath: "/private/tmp/project-b", isDirectory: true)
        )

        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertEqual(first.relationship(to: second), .distinctProjects)
    }

    func test_projectIdentifier_whenRawValueIsInvalid_shouldRejectIt() {
        XCTAssertNil(ProjectIdentifier(rawValue: "project-1"))
        XCTAssertNil(ProjectIdentifier(rawValue: ProjectIdentifier.prefix + String(repeating: "A", count: 64)))
    }

    func test_resolve_whenURLIsNotLocalFile_shouldRejectIt() {
        XCTAssertThrowsError(
            try resolver.resolve(rootDirectory: URL(string: "https://example.com/project")!)
        ) { error in
            XCTAssertEqual(error as? ProjectIdentityError, .nonFileURL)
        }
    }

    func test_semanticStatus_whenEnumerated_shouldProvideTextAndShapeCues() {
        for status in DevSpaceSemanticStatus.allCases {
            XCTAssertFalse(status.token.canonicalLabel.isEmpty)
            XCTAssertFalse(status.token.systemImage.isEmpty)
        }
    }

    func test_appLanguage_whenPreferredLanguageIsChinese_shouldSelectSimplifiedChinese() {
        XCTAssertEqual(
            AppLanguage.preferred(from: ["zh-Hans-CN", "en-US"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppLanguage.preferred(from: ["fr-FR"]),
            .english
        )
    }

    @MainActor
    func test_appLanguageSettings_whenSelectionChanges_shouldPersistIt() {
        let suiteName = "DevWorkspaceTests.Language.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppLanguageSettings(
            userDefaults: userDefaults,
            defaultLanguage: .english
        )

        settings.language = .simplifiedChinese

        let restoredSettings = AppLanguageSettings(
            userDefaults: userDefaults,
            defaultLanguage: .english
        )
        XCTAssertEqual(restoredSettings.language, .simplifiedChinese)
    }

    func test_appLanguage_whenLocalizingKnownKey_shouldUseSelectedLanguage() {
        XCTAssertEqual(
            AppLanguage.english.localized("settings.general.language"),
            "Language"
        )
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.localized("settings.general.language"),
            "语言"
        )
    }

    func test_globalShortcut_whenFormatted_shouldUseCanonicalModifierOrder() {
        let shortcut = GlobalShortcut(
            keyCode: 0,
            key: "A",
            modifiers: [.command, .shift, .control, .option]
        )

        XCTAssertEqual(shortcut.displayName, "⌃⌥⇧⌘A")
        XCTAssertTrue(shortcut.isValid)
        XCTAssertFalse(
            GlobalShortcut(
                keyCode: 0,
                key: "A",
                modifiers: []
            ).isValid
        )
        XCTAssertFalse(
            GlobalShortcut(
                keyCode: 0,
                key: "A",
                modifiers: [.shift]
            ).isValid
        )
    }

    @MainActor
    func test_shortcutSettings_whenShortcutRegisters_shouldPersistAndInvokeIt() {
        let suiteName = "DevWorkspaceTests.Shortcut.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let registrar = TestGlobalShortcutRegistrar()
        var invocationCount = 0
        let settings = AppShortcutSettings(
            registrar: registrar,
            userDefaults: userDefaults
        ) {
            invocationCount += 1
        }
        let replacement = GlobalShortcut(
            keyCode: 1,
            key: "S",
            modifiers: [.control, .option]
        )

        XCTAssertTrue(settings.apply(replacement))
        registrar.invoke()

        XCTAssertEqual(settings.shortcut, replacement)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(
            userDefaults.integer(forKey: AppShortcutSettings.keyCodeKey),
            1
        )
        XCTAssertEqual(
            userDefaults.string(forKey: AppShortcutSettings.keyLabelKey),
            "S"
        )

        let restoredSettings = AppShortcutSettings(
            registrar: TestGlobalShortcutRegistrar(),
            userDefaults: userDefaults,
            onInvoke: {}
        )
        XCTAssertEqual(restoredSettings.shortcut, replacement)
        XCTAssertTrue(restoredSettings.isShortcutRegistered)
    }

    @MainActor
    func test_shortcutSettings_whenReplacementConflicts_shouldKeepPreviousShortcut() {
        let suiteName = "DevWorkspaceTests.Shortcut.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let conflictingShortcut = GlobalShortcut(
            keyCode: 1,
            key: "S",
            modifiers: [.command, .option]
        )
        let registrar = TestGlobalShortcutRegistrar(
            conflictingShortcuts: [conflictingShortcut]
        )
        let settings = AppShortcutSettings(
            registrar: registrar,
            userDefaults: userDefaults,
            onInvoke: {}
        )

        XCTAssertFalse(settings.apply(conflictingShortcut))

        XCTAssertEqual(settings.shortcut, .defaultWorkspace)
        XCTAssertEqual(registrar.activeShortcut, .defaultWorkspace)
        XCTAssertEqual(
            settings.registrationIssue,
            .conflict(conflictingShortcut)
        )
    }

    @MainActor
    func test_shortcutSettings_whenLaunchRegistrationFails_shouldRestoreMenuBarIcon() {
        let suiteName = "DevWorkspaceTests.Shortcut.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set(
            false,
            forKey: AppShortcutSettings.menuBarIconVisibleKey
        )
        let registrar = TestGlobalShortcutRegistrar(
            conflictingShortcuts: [.defaultWorkspace]
        )

        let settings = AppShortcutSettings(
            registrar: registrar,
            userDefaults: userDefaults,
            onInvoke: {}
        )

        XCTAssertFalse(settings.isShortcutRegistered)
        XCTAssertTrue(settings.isMenuBarIconVisible)
        XCTAssertTrue(settings.effectiveMenuBarIconVisibility)
        XCTAssertTrue(
            userDefaults.bool(
                forKey: AppShortcutSettings.menuBarIconVisibleKey
            )
        )
    }

    func test_menuBarClickAction_whenRightMouseIsReleased_shouldShowContextMenu() {
        XCTAssertEqual(
            MenuBarClickAction(eventType: .rightMouseUp),
            .showContextMenu
        )
    }

    func test_menuBarClickAction_whenPrimaryMouseIsReleased_shouldTogglePopover() {
        XCTAssertEqual(
            MenuBarClickAction(eventType: .leftMouseUp),
            .togglePopover
        )
    }

    @MainActor
    func test_contextMenu_whenBuilt_shouldExposeQuitActionAndKeyboardShortcut() throws {
        let suiteName = "DevWorkspaceTests.Menu.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let languageSettings = AppLanguageSettings(
            userDefaults: userDefaults,
            defaultLanguage: .simplifiedChinese
        )
        let identity = try resolver.resolve(
            rootDirectory: URL(
                fileURLWithPath: "/private/tmp/menu-bar-test",
                isDirectory: true
            ),
            declaredMetadataID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000043"
            )
        )
        let controller = MenuBarController(
            store: WorkspaceStore(
                project: ProjectReference(identity: identity, name: "Example"),
                provider: PreviewWorkspaceSnapshotProvider()
            ),
            languageSettings: languageSettings,
            shortcutSettings: AppShortcutSettings(
                registrar: TestGlobalShortcutRegistrar(),
                userDefaults: userDefaults,
                onInvoke: {}
            )
        )

        let menu = controller.makeContextMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            ["打开工作区", "设置…", "", "退出 DevWorkspace"]
        )
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertNotNil(menu.items.last?.action)

        languageSettings.language = .english

        XCTAssertEqual(
            controller.makeContextMenu().items.map(\.title),
            ["Open Workspace", "Settings…", "", "Quit DevWorkspace"]
        )
    }

    @MainActor
    func test_workspaceMenuIcon_whenLoaded_shouldBeATemplateImage() {
        let icon = NSImage(
            named: NSImage.Name(
                DevSpaceProduct.workspace.icon.menuBarAssetName
            )
        )

        XCTAssertNotNil(icon)
        XCTAssertEqual(icon?.isTemplate, true)
    }
}

@MainActor
private final class TestGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private let conflictingShortcuts: Set<GlobalShortcut>
    private var handler: (@MainActor () -> Void)?
    private(set) var activeShortcut: GlobalShortcut?

    init(conflictingShortcuts: Set<GlobalShortcut> = []) {
        self.conflictingShortcuts = conflictingShortcuts
    }

    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @MainActor () -> Void
    ) throws {
        guard !conflictingShortcuts.contains(shortcut) else {
            throw GlobalShortcutRegistrationError.conflict
        }
        activeShortcut = shortcut
        self.handler = handler
    }

    func invoke() {
        handler?()
    }
}
