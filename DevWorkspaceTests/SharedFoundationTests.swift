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
            )
        )

        let menu = controller.makeContextMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            ["打开工作区", "设置…", "", "退出 DevWorkspace"]
        )
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
        XCTAssertNotNil(menu.items.last?.action)
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
