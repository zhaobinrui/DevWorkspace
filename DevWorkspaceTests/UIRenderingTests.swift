import AppKit
import SwiftUI
import XCTest
@testable import DevWorkspace

final class UIRenderingTests: XCTestCase {
    @MainActor
    func test_captureWorkspace_whenExplicitlyRequested_shouldRenderKeyStates() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp/devworkspace-capture-dashboard")
        guard let label = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw XCTSkip("Create the dashboard capture marker to render visual QA fixtures.")
        }
        let output = URL(fileURLWithPath: "/private/tmp/devworkspace-dashboard-qa/\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "DevWorkspaceTests.Dashboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageSettings(userDefaults: defaults, defaultLanguage: .simplifiedChinese)
        let project = ProjectReference(identity: try LocalProjectIdentityResolver().resolve(
            rootDirectory: URL(fileURLWithPath: "/Projects/DevSpace"),
            declaredMetadataID: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        ), name: "DevSpace")
        let sibling = ProjectReference(identity: try LocalProjectIdentityResolver().resolve(
            rootDirectory: URL(fileURLWithPath: "/Projects/sample-api"),
            declaredMetadataID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        ), name: "sample-api")
        let date = Date(timeIntervalSince1970: 1_789_999_000)
        let git = GitSummary(branch: "feature/workspace-overview", changedFileCount: 8, commitsAhead: 2, commitsBehind: 0, upstream: "origin/main")
        let processes = [testProcess(pid: 31415, directory: "/Projects/DevSpace"), testProcess(pid: 27182, directory: "/Projects/DevSpace/server")]
        for scenario in ["light", "dark", "empty", "error", "narrow", "onboarding", "unavailable", "non-git", "processes", "processes-error", "processes-empty", "compose", "compose-error"] {
            let failed = scenario == "error" || scenario == "processes-error"
            var readings = WorkspaceReadings(
                git: SourceReading(value: git, checkedAt: date, attemptedAt: date.addingTimeInterval(60), failure: failed ? .init(kind: .permissionDenied) : nil),
                ports: .success(scenario == "empty" ? [] : processes, at: date)
            )
            if scenario.hasPrefix("processes") {
                readings.ports = SourceReading(value: scenario == "processes-empty" ? [] : [processes[0], testProcess(pid: 27182, directory: "/Projects/sample-api"), testProcess(pid: 31000, directory: "/Projects/unregistered")],
                                              checkedAt: date, attemptedAt: date.addingTimeInterval(60), failure: failed ? .init(kind: .permissionDenied) : nil)
            }
            if scenario == "non-git" { readings.git = .success(nil, at: date) }
            if scenario == "unavailable" {
                readings.git = .failed(LocalReadFailure(kind: .permissionDenied), at: date)
                readings.ports = .failed(LocalReadFailure(kind: .timedOut), at: date)
            }
            if scenario.hasPrefix("compose") {
                let containers = [
                    ComposeContainer(id: "abc1234567890123", projectName: "devspace", serviceName: "api",
                                     state: .running, health: .healthy,
                                     ports: [ComposePublishedPort(address: "127.0.0.1", target: 8080, published: 18080, transport: "tcp")]),
                    ComposeContainer(id: "def1234567890123", projectName: "devspace", serviceName: "db",
                                     state: .running, health: .unhealthy, ports: []),
                ]
                let status = ComposeProjectStatus(configurationName: "compose.yaml", projectName: "devspace", containers: containers)
                readings.compose = SourceReading(value: status, checkedAt: date, attemptedAt: date.addingTimeInterval(60),
                                                 failure: scenario == "compose-error" ? .init(kind: .dockerDaemonUnavailable) : nil)
            }
            let snapshot = WorkspaceSnapshot(project: project, lifecycle: .observed, git: git, services: [], observedAt: date, freshness: .current, origin: .local, readings: readings)
            let catalog = scenario == "onboarding" ? ProjectCatalog() : ProjectCatalog(projects: [project, sibling], selectedID: project.id)
            let store = WorkspaceStore(provider: DashboardCaptureProvider(snapshot: snapshot), catalogRepository: DashboardCaptureCatalog(catalog: catalog))
            await store.refresh()
            let size = NSSize(width: scenario == "narrow" ? 760 : 1040, height: 760)
            let scheme: ColorScheme = scenario == "dark" ? .dark : .light
            let renderer = ImageRenderer(content: AppLanguageRootView(settings: language) {
                WorkspaceDashboardView(store: store, refresh: {}, showUserProcesses: scenario.hasPrefix("processes"))
                    .defaultAppStorage(defaults)
                    .environment(\.workspaceStaticRendering, true)
                    .environment(\.colorScheme, scheme)
                    .frame(width: size.width, height: size.height)
                    .background(scheme == .dark ? Color.black : Color.white)
            })
            renderer.scale = 2
            // macOS 26+ can automatically export PQ PNGs after seeing HDR application icons.
            if #available(macOS 26.0, *) { renderer.allowedDynamicRange = .standard }
            // Render the SwiftUI hierarchy directly: cacheDisplay omits deferred GPU text layers on newer macOS.
            let image = try XCTUnwrap(renderer.cgImage)
            // Normalize the PNG profile as well: standard luminance alone may still encode PQ.
            let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: image).converting(to: .sRGB, renderingIntent: .perceptual))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("\(scenario).png"))
            if scenario.hasPrefix("compose") {
                let detail = ImageRenderer(content: AppLanguageRootView(settings: language) {
                    WorkspaceOverviewView(store: store)
                        .frame(width: 720, alignment: .topLeading)
                        .padding(20)
                        .background(Color.white)
                })
                detail.scale = 2
                if #available(macOS 26.0, *) { detail.allowedDynamicRange = .standard }
                let detailBitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(detail.cgImage))
                    .converting(to: .sRGB, renderingIntent: .perceptual))
                try XCTUnwrap(detailBitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(scenario)-detail.png"))
            }
        }
    }

    @MainActor
    func test_captureProjectActions_whenExplicitlyRequested_shouldRenderSavedAndDiscoveredLinks() async throws {
        guard FileManager.default.fileExists(atPath: "/private/tmp/devworkspace-capture-dashboard") else {
            throw XCTSkip("Create the dashboard capture marker to render action fixtures.")
        }
        let project = try testProject(URL(fileURLWithPath: "/Projects/sample-api"))
        let link = ProjectLink(name: "API 文档", url: URL(string: "http://localhost:9090/api/docs")!)
        let preferences = ProjectPreferences(projectID: project.id,
            editor: ProjectEditor(bundleIdentifier: "com.jetbrains.intellij", applicationURL: URL(fileURLWithPath: "/Applications/IntelliJ IDEA.app"), name: "IntelliJ IDEA"), links: [link])
        let catalog = ProjectCatalog(projects: [project], selectedID: project.id, preferences: [preferences])
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: DashboardCaptureCatalog(catalog: catalog), configurationReader: ActionCaptureConfiguration())
        await store.discoverConfiguration()
        let output = URL(fileURLWithPath: "/private/tmp/devworkspace-dashboard-qa/actions")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "DevWorkspaceTests.Actions.Capture")!
        defer { defaults.removePersistentDomain(forName: "DevWorkspaceTests.Actions.Capture") }
        let language = AppLanguageSettings(userDefaults: defaults, defaultLanguage: .simplifiedChinese)
        for variant in ["light", "dark", "collapsed"] {
            let scheme: ColorScheme = variant == "dark" ? .dark : .light
            defaults.set(variant != "collapsed", forKey: "workspace.commonApplicationsExpanded")
            let renderer = ImageRenderer(content: AppLanguageRootView(settings: language) {
                ProjectActionsView(store: store, configurationExpanded: variant != "collapsed")
                    .defaultAppStorage(defaults)
                    .environment(\.workspaceStaticRendering, true)
                    .environment(\.colorScheme, scheme)
                    .padding(24).frame(width: 790)
                    .background(scheme == .dark ? Color.black : Color.white)
            })
            renderer.scale = 2
            // macOS 26+ can automatically export PQ PNGs after seeing HDR application icons.
            if #available(macOS 26.0, *) { renderer.allowedDynamicRange = .standard }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage)).converting(to: .sRGB, renderingIntent: .perceptual))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(variant + ".png"))
        }
    }

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

private struct DashboardCaptureProvider: WorkspaceSnapshotProviding {
    let snapshot: WorkspaceSnapshot
    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot { snapshot }
}

private struct DashboardCaptureCatalog: ProjectCatalogPersisting {
    let catalog: ProjectCatalog
    func load() throws -> ProjectCatalog { catalog }
    func save(_ catalog: ProjectCatalog) throws {}
}

private struct ActionCaptureConfiguration: ProjectConfigurationReading {
    func read(root: URL) async throws -> ProjectDiscovery {
        ProjectDiscovery(links: [DiscoveredProjectLink(name: "Service", url: URL(string: "http://localhost:9090/api")!, source: "src/main/resources/application.yml · server.port"),
            DiscoveredProjectLink(name: "API docs", url: URL(string: "http://localhost:9090/api/docs")!, source: "src/main/resources/application.yml · springdoc.swagger-ui.path")], dockerFiles: ["Dockerfile", "compose.yaml"])
    }
}
