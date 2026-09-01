import AppKit
import SwiftUI
import XCTest
@testable import DevWorkspace

final class UIRenderingTests: XCTestCase {
    @MainActor
    func test_capturePrototypeScreens_whenExplicitlyRequested() async throws {
        let captureMarker = "/private/tmp/devworkspace-capture-ui"
        guard FileManager.default.fileExists(atPath: captureMarker) else {
            throw XCTSkip("Create \(captureMarker) to write visual QA captures.")
        }

        let outputDirectory = URL(
            fileURLWithPath: "/private/tmp/devworkspace-ui-qa",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let suiteName = "DevWorkspaceTests.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let languageSettings = AppLanguageSettings(
            userDefaults: defaults,
            defaultLanguage: .simplifiedChinese
        )
        let store = try makeStore()
        await store.refresh()
        let requestedSkin = ProcessInfo.processInfo.environment[
            "DEVWORKSPACE_CAPTURE_SKIN"
        ].flatMap(MenuBarSkin.init(rawValue:))
        let skins = requestedSkin.map { [$0] } ?? MenuBarSkin.allCases

        for skin in skins {
            let appearanceSettings = AppearanceSettings(userDefaults: defaults)
            appearanceSettings.skin = skin
            appearanceSettings.glow = skin == .focusedFrost ? .off : .subtle
            appearanceSettings.colorMode = skin == .crystalAir ? .light : .dark
            try await render(
                AppLanguageRootView(settings: languageSettings) {
                    ZStack {
                        validationBackdrop(for: skin)
                        MenuBarContentView(
                            store: store,
                            appearanceSettings: appearanceSettings,
                            openWorkspace: {},
                            openProjectFolder: { _ in },
                            openExternalURL: { _ in },
                            copyText: { _ in },
                            refresh: {}
                        )
                    }
                    .frame(width: 520, height: 680)
                    .environment(
                        \.colorScheme,
                        skin == .crystalAir ? .light : .dark
                    )
                },
                size: NSSize(width: 520, height: 680),
                destination: outputDirectory
                    .appending(path: "menu-\(skin.rawValue).png")
            )
        }

        try writeComparisons(
            outputDirectory: outputDirectory,
            skins: Set(skins)
        )

        let appearanceSettings = AppearanceSettings(userDefaults: defaults)
        appearanceSettings.skin = .softGlow
        appearanceSettings.glow = .subtle
        appearanceSettings.colorMode = .dark
        try await render(
            AppLanguageRootView(settings: languageSettings) {
                AppearanceSettingsPane(
                    appearanceSettings: appearanceSettings
                )
                .frame(
                    width: DevSpaceLayout.settingsWidth,
                    height: DevSpaceLayout.settingsHeight
                )
                .preferredColorScheme(
                    appearanceSettings.colorMode.preferredColorScheme
                )
                .environment(\.colorScheme, .dark)
            },
            size: NSSize(
                width: DevSpaceLayout.settingsWidth,
                height: DevSpaceLayout.settingsHeight
            ),
            destination: outputDirectory.appending(path: "appearance-settings.png")
        )

        let notificationSettings = NotificationSettings(userDefaults: defaults)
        let notificationManager = UIRenderingNotificationManager()
        try await render(
            SettingsView(
                languageSettings: languageSettings,
                shortcutSettings: AppShortcutSettings(
                    registrar: UIRenderingShortcutRegistrar(),
                    userDefaults: defaults,
                    onInvoke: {}
                ),
                appearanceSettings: appearanceSettings,
                notificationSettings: notificationSettings,
                notificationManager: notificationManager
            ),
            size: NSSize(
                width: DevSpaceLayout.settingsWidth,
                height: DevSpaceLayout.settingsHeight
            ),
            destination: outputDirectory.appending(path: "general-settings.png")
        )
    }

    @MainActor
    private func makeStore() throws -> WorkspaceStore {
        let root = URL(
            fileURLWithPath: "/private/tmp/devworkspace-ui-project",
            isDirectory: true
        )
        let project = ProjectReference(
            identity: try LocalProjectIdentityResolver().resolve(
                rootDirectory: root,
                declaredMetadataID: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000099"
                )
            ),
            name: "ECM API"
        )
        return WorkspaceStore(
            project: project,
            provider: PreviewWorkspaceSnapshotProvider()
        )
    }

    @MainActor
    private func render<Content: View>(
        _ content: Content,
        size: NSSize,
        destination: URL
    ) async throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        // SwiftUI can resolve symbols and observable state on the next main-loop turn.
        // Waiting before snapshotting avoids incomplete bitmap evidence in visual QA.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(80))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        guard
            let warmupBitmap = hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        else {
            XCTFail("Unable to allocate a bitmap for \(destination.lastPathComponent)")
            return
        }

        // The first cache pass initializes deferred text and SF Symbol layers.
        // Capture a fresh bitmap after that pass so QA evidence is complete.
        hostingView.cacheDisplay(in: hostingView.bounds, to: warmupBitmap)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(40))
        hostingView.needsDisplay = true
        hostingView.displayIfNeeded()

        guard
            let bitmap = hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        else {
            XCTFail("Unable to allocate a bitmap for \(destination.lastPathComponent)")
            return
        }

        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Unable to encode \(destination.lastPathComponent) as PNG")
            return
        }
        try data.write(to: destination, options: .atomic)
    }

    private func validationBackdrop(for skin: MenuBarSkin) -> some View {
        Group {
            switch skin {
            case .crystalAir:
                Color(red: 0.55, green: 0.72, blue: 0.9)
            case .softGlow:
                Color(red: 0.045, green: 0.09, blue: 0.2)
            case .focusedFrost:
                Color(red: 0.025, green: 0.055, blue: 0.12)
            }
        }
    }

    private func writeComparisons(
        outputDirectory: URL,
        skins: Set<MenuBarSkin>
    ) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = repositoryRoot.appending(path: "product-images")
        let implementationCrop = NormalizedTopCrop(
            x: 160.0 / 1040.0,
            y: 149.0 / 1360.0,
            width: 720.0 / 1040.0,
            height: 1062.0 / 1360.0
        )
        let comparisons: [(
            skin: MenuBarSkin,
            sourceName: String,
            sourceCrop: NormalizedTopCrop
        )] = [
            (
                .crystalAir,
                "devworkspace-crystal-air-axure.png",
                NormalizedTopCrop(
                    x: 235.0 / 1536.0,
                    y: 175.0 / 1024.0,
                    width: 548.0 / 1536.0,
                    height: 748.0 / 1024.0
                )
            ),
            (
                .softGlow,
                "devworkspace-soft-glow-axure.png",
                NormalizedTopCrop(
                    x: 322.0 / 1536.0,
                    y: 180.0 / 1024.0,
                    width: 562.0 / 1536.0,
                    height: 760.0 / 1024.0
                )
            ),
            (
                .focusedFrost,
                "devworkspace-focused-frost-axure.png",
                NormalizedTopCrop(
                    x: 204.0 / 1536.0,
                    y: 165.0 / 1024.0,
                    width: 560.0 / 1536.0,
                    height: 755.0 / 1024.0
                )
            ),
        ]

        for comparison in comparisons {
            guard skins.contains(comparison.skin) else {
                continue
            }
            try composeComparison(
                referenceURL: sourceDirectory.appending(
                    path: comparison.sourceName
                ),
                referenceCrop: comparison.sourceCrop,
                implementationURL: outputDirectory.appending(
                    path: "menu-\(comparison.skin.rawValue).png"
                ),
                implementationCrop: implementationCrop,
                destination: outputDirectory.appending(
                    path: "comparison-\(comparison.skin.rawValue).png"
                ),
                usesDarkCanvas: comparison.skin != .crystalAir
            )
        }
    }

    private func composeComparison(
        referenceURL: URL,
        referenceCrop: NormalizedTopCrop,
        implementationURL: URL,
        implementationCrop: NormalizedTopCrop,
        destination: URL,
        usesDarkCanvas: Bool
    ) throws {
        guard
            let reference = NSImage(contentsOf: referenceURL),
            let implementation = NSImage(contentsOf: implementationURL)
        else {
            XCTFail("Unable to load visual QA comparison inputs")
            return
        }

        let canvasSize = NSSize(width: 1_440, height: 1_040)
        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()

        (usesDarkCanvas ? NSColor.black : NSColor.white).setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let labelColor = usesDarkCanvas ? NSColor.white : NSColor.black
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: labelColor,
        ]
        NSString(string: "Reference").draw(
            at: NSPoint(x: 40, y: 990),
            withAttributes: labelAttributes
        )
        NSString(string: "Implementation").draw(
            at: NSPoint(x: 750, y: 990),
            withAttributes: labelAttributes
        )

        draw(
            reference,
            normalizedCrop: referenceCrop,
            columnX: 40,
            canvasHeight: canvasSize.height
        )
        draw(
            implementation,
            normalizedCrop: implementationCrop,
            columnX: 750,
            canvasHeight: canvasSize.height
        )
        canvas.unlockFocus()

        guard
            let data = canvas.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Unable to encode visual QA comparison")
            return
        }
        try png.write(to: destination, options: .atomic)
    }

    private func draw(
        _ image: NSImage,
        normalizedCrop: NormalizedTopCrop,
        columnX: CGFloat,
        canvasHeight: CGFloat
    ) {
        let source = normalizedCrop.sourceRect(in: image.size)
        let maxSize = NSSize(width: 650, height: 920)
        let scale = min(
            maxSize.width / source.width,
            maxSize.height / source.height
        )
        let destinationSize = NSSize(
            width: source.width * scale,
            height: source.height * scale
        )
        let destination = NSRect(
            x: columnX + (maxSize.width - destinationSize.width) / 2,
            y: canvasHeight - 70 - destinationSize.height,
            width: destinationSize.width,
            height: destinationSize.height
        )

        image.draw(
            in: destination,
            from: source,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

@MainActor
private final class UIRenderingNotificationManager: UserNotificationManaging {
    func authorizationState() async -> NotificationAuthorizationState {
        .notDetermined
    }

    func requestAuthorization() async -> NotificationAuthorizationState {
        .notDetermined
    }

    func deliver(_ notification: WorkspaceLocalNotification) async throws {}
}

@MainActor
private final class UIRenderingShortcutRegistrar: GlobalShortcutRegistering {
    func register(
        _ shortcut: GlobalShortcut,
        handler: @escaping @MainActor () -> Void
    ) throws {}
}

private struct NormalizedTopCrop {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    func sourceRect(in imageSize: NSSize) -> NSRect {
        let cropHeight = height * imageSize.height
        return NSRect(
            x: x * imageSize.width,
            y: imageSize.height - (y * imageSize.height) - cropHeight,
            width: width * imageSize.width,
            height: cropHeight
        )
    }
}
