import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class ProjectActionsTests: XCTestCase {
    func test_preferences_whenRestarted_shouldRestorePerProjectEditorAndLinks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try testProject(directory.appendingPathComponent("a"))
        let b = try testProject(directory.appendingPathComponent("b"))
        let repository = FileProjectCatalogRepository(fileURL: directory.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [a, b], selectedID: a.id))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        let choice = ProjectPreferences(projectID: a.id, editor: editor, links: [link])
        try store.savePreferences(choice)
        let restored = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        XCTAssertEqual(restored.preferences(for: a.id), choice)
        XCTAssertNil(restored.preferences(for: b.id).editor)
        restored.removeSelectedProject()
        XCTAssertTrue(restored.catalog.preferences.isEmpty)
    }

    func test_catalog_withoutNewFields_shouldMigrateWithoutLosingProjects() throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectCatalog(projects: [project], selectedID: project.id))) as? [String: Any])
        object.removeValue(forKey: "preferences")
        let restored = try JSONDecoder().decode(ProjectCatalog.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.projects, [project])
        XCTAssertTrue(restored.preferences.isEmpty)
    }

    func test_editor_firstOpenThenReopen_shouldChooseOnceAndRemember() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        let opener = ActionOpenerFixture(); opener.choice = editor
        let controller = ProjectActionsController(opener: opener)
        await controller.editor(project: project, store: store)
        await controller.editor(project: project, store: store)
        XCTAssertEqual(opener.choices, 1)
        XCTAssertEqual(opener.opened, [project.rootDirectory, project.rootDirectory])
        XCTAssertEqual(store.preferences(for: project.id).editor, editor)
        opener.error = ProjectActionFailure.missingApplication
        await controller.editor(project: project, store: store)
        XCTAssertEqual(controller.feedbackKey, "actions.error.missingApplication")
        XCTAssertEqual(store.preferences(for: project.id).editor, editor)
    }

    func test_editor_whenSaveFailsOrPickerCancelled_shouldNotLaunch() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: FailingSaveRepository(catalog: ProjectCatalog(projects: [project], selectedID: project.id)))
        let opener = ActionOpenerFixture()
        let controller = ProjectActionsController(opener: opener)
        await controller.editor(project: project, store: store)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertNil(controller.failure)
        opener.choice = editor
        await controller.editor(project: project, store: store)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertEqual(controller.failure?.kind, .permissionDenied)
        XCTAssertNil(store.preferences(for: project.id).editor)
    }

    func test_editor_whenProjectRemovedDuringPicker_shouldNotRecreateOrLaunch() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        let opener = ActionOpenerFixture(); opener.choice = editor
        opener.onChoose = { store.removeSelectedProject() }
        let controller = ProjectActionsController(opener: opener)
        await controller.editor(project: project, store: store)
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertTrue(store.catalog.preferences.isEmpty)
    }

    func test_URLPolicy_shouldRejectCredentialAndExecutableURLs() {
        for value in ["file:///tmp/a", "javascript:alert(1)", "https://user:secret@example.com", "http://localhost:0", "http://localhost:99999", "https://example.com?token=secret", "https://example.com/#secret", "http://localhost:${PORT}", "http://localhost/a b"] {
            XCTAssertNil(ProjectURLPolicy.validated(value), value)
        }
        XCTAssertNotNil(ProjectURLPolicy.validated("https://example.com/docs"))
        XCTAssertNotNil(ProjectURLPolicy.validated("http://[::1]:8080/docs"))
    }

    func test_staticConfiguration_shouldExtractSpringPathsAndLiteralScriptPort() throws {
        let yaml = """
        server:
          port: 9090
          ssl:
            enabled: true
          servlet:
            context-path: /api
        springdoc:
          swagger-ui:
            path: /docs
          api-docs:
            path: /schema
        """
        let parsed = try LocalProjectConfigurationReader.parse(data: Data(yaml.utf8), source: "application.yml")
        XCTAssertEqual(parsed.links.map(\.url.absoluteString), ["https://localhost:9090/api", "https://localhost:9090/api/docs", "https://localhost:9090/api/schema"])
        let node = try LocalProjectConfigurationReader.parse(data: Data(#"{"scripts":{"dev":"vite --port 5173","start":"node app.js --port ${PORT}","test":"test --port 80"},"documentation":"https://example.com/docs","password":"never-show"}"#.utf8), source: "package.json")
        XCTAssertEqual(node.links.map(\.url.absoluteString), ["http://localhost:5173", "https://example.com/docs"])
        XCTAssertFalse(String(describing: node).contains("never-show"))
    }

    func test_configuration_whenUnresolvedOrMalformed_shouldNotGuess() throws {
        for input in ["server.port=${PORT:8080}", "server.port=abc", "server.port=65536", "server.port=8080\nserver.ssl.enabled=maybe"] {
            XCTAssertThrowsError(try LocalProjectConfigurationReader.parse(data: Data(input.utf8), source: "application.properties"))
        }
        XCTAssertThrowsError(try LocalProjectConfigurationReader.parse(data: Data("server:\n  port: 8080\n---\nserver:\n  port: 80".utf8), source: "application.yml"))
        XCTAssertThrowsError(try LocalProjectConfigurationReader.parse(data: Data("{".utf8), source: "package.json")) { error in
            XCTAssertEqual((error as? LocalReadFailure)?.kind, .invalidOutput)
        }
    }

    func test_discovery_whenEmptyDockerAndEscapingSymlink_shouldReportDistinctResults() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = LocalProjectConfigurationReader()
        let empty = try await reader.read(root: directory)
        XCTAssertEqual(empty, ProjectDiscovery())
        try Data("FROM scratch".utf8).write(to: directory.appendingPathComponent("Dockerfile"))
        try Data("services: {}".utf8).write(to: directory.appendingPathComponent("compose.yaml"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("package.json"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let result = try await reader.read(root: directory)
        XCTAssertEqual(result.dockerFiles, ["Dockerfile", "compose.yaml"])
        XCTAssertEqual(result.issues.first?.failure.kind, .permissionDenied)
        XCTAssertTrue(result.links.isEmpty)
    }

    func test_discovery_whenMavenAndGradleModulesContainApplicationConfig_shouldFindStaticLinksWithSources() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let maven = directory.appendingPathComponent("controller/src/main/resources", isDirectory: true)
        let gradle = directory.appendingPathComponent("api/src/main/resources", isDirectory: true)
        let unrelated = directory.appendingPathComponent("unrelated/src/main/resources", isDirectory: true)
        for folder in [maven, gradle, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("<project/>".utf8).write(to: directory.appendingPathComponent("controller/pom.xml"))
        try Data("plugins {}".utf8).write(to: directory.appendingPathComponent("api/build.gradle.kts"))
        let yaml = "server:\n  port: 8080\nspringdoc:\n  swagger-ui:\n    path: /swagger-ui.html\n  api-docs:\n    path: /v3/api-docs\n"
        try Data(yaml.utf8).write(to: maven.appendingPathComponent("application.yml"))
        try Data("server.port=8443".utf8).write(to: maven.appendingPathComponent("application-https.yml"))
        try Data("server.port=9090".utf8).write(to: gradle.appendingPathComponent("application.properties"))
        try Data("server.port=7777".utf8).write(to: unrelated.appendingPathComponent("application.properties"))

        let discovery = try await LocalProjectConfigurationReader().read(root: directory)
        XCTAssertTrue(discovery.issues.isEmpty)
        XCTAssertEqual(Set(discovery.links.map(\.url.absoluteString)), Set([
            "http://localhost:9090", "http://localhost:8080", "http://localhost:8080/swagger-ui.html",
            "http://localhost:8080/v3/api-docs",
        ]))
        XCTAssertTrue(discovery.links.contains { $0.source == "controller/src/main/resources/application.yml · server.port" })
        XCTAssertFalse(discovery.links.contains { $0.url.port == 8443 || $0.url.port == 7777 })
    }

    func test_discovery_whenModuleConfigurationEscapesProject_shouldReportPermissionDenied() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: outside) }
        let resources = directory.appendingPathComponent("api/src/main/resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("<project/>".utf8).write(to: directory.appendingPathComponent("api/pom.xml"))
        let external = outside.appendingPathComponent("application.yml")
        try Data("server:\n  port: 9999".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("application.yml"), withDestinationURL: external)
        let linkedModule = directory.appendingPathComponent("linked")
        let externalResources = outside.appendingPathComponent("main/resources", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedModule, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalResources, withIntermediateDirectories: true)
        try Data("<project/>".utf8).write(to: linkedModule.appendingPathComponent("pom.xml"))
        try Data("server.port=8888".utf8).write(to: externalResources.appendingPathComponent("application.properties"))
        try FileManager.default.createSymbolicLink(at: linkedModule.appendingPathComponent("src"), withDestinationURL: outside)

        let discovery = try await LocalProjectConfigurationReader().read(root: directory)
        XCTAssertTrue(discovery.links.isEmpty)
        XCTAssertTrue(discovery.issues.contains { $0.source == "api/src/main/resources/application.yml" && $0.failure.kind == .permissionDenied })
        XCTAssertTrue(discovery.issues.contains { $0.source == "linked/src/main/resources/application.properties" && $0.failure.kind == .permissionDenied })
    }

    func test_discovery_whenOversizedOrPermissionDenied_shouldReportFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("package.json")
        try Data(repeating: 32, count: 262_145).write(to: file)
        let reader = LocalProjectConfigurationReader()
        let oversized = try await reader.read(root: directory)
        XCTAssertEqual(oversized.issues.first?.failure.kind, .outputLimit)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let denied = try await reader.read(root: directory)
        XCTAssertEqual(denied.issues.first?.failure.kind, .permissionDenied)
    }

    func test_discovery_whenReadFails_shouldRetainTimestampThenRecoverToEmpty() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let discovery = ProjectDiscovery(links: [DiscoveredProjectLink(name: "API", url: link.url, source: "application.properties · server.port")])
        let reader = ConfigurationFixture(results: [.success(discovery), .failure(LocalReadFailure(kind: .permissionDenied)), .success(ProjectDiscovery())])
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(), configurationReader: reader)
        await store.discoverConfiguration()
        let date = store.discovery?.checkedAt
        await store.discoverConfiguration()
        XCTAssertEqual(store.discovery?.value, discovery)
        XCTAssertEqual(store.discovery?.checkedAt, date)
        XCTAssertEqual(store.discovery?.failure?.kind, .permissionDenied)
        await store.discoverConfiguration()
        XCTAssertEqual(store.discovery?.value, ProjectDiscovery())
        XCTAssertNil(store.discovery?.failure)
    }

    func test_discovery_whenPartialFailure_shouldRetainFailedFileAndRefreshOtherFiles() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let old = DiscoveredProjectLink(name: "API", url: link.url, source: "application.properties · server.port")
        let new = DiscoveredProjectLink(name: "Web", url: URL(string: "http://localhost:5173")!, source: "package.json · scripts.dev")
        let reader = ConfigurationFixture(results: [.success(ProjectDiscovery(links: [old])),
            .success(ProjectDiscovery(links: [new], issues: [ConfigurationIssue(source: "application.properties", failure: .init(kind: .invalidOutput))]))])
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(), configurationReader: reader)
        await store.discoverConfiguration()
        let date = store.discovery?.checkedAt
        await store.discoverConfiguration()
        XCTAssertEqual(store.discovery?.value?.links, [new, old])
        XCTAssertEqual(store.discovery?.checkedAt, date)
        XCTAssertEqual(store.discovery?.failure?.kind, .invalidOutput)
    }

    func test_discovery_whenSelectionChanges_shouldDiscardLateResult() async throws {
        let a = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let b = try testProject(URL(fileURLWithPath: "/private/tmp/b"))
        let reader = DelayedConfigurationFixture()
        let store = WorkspaceStore(project: a, provider: PreviewWorkspaceSnapshotProvider(),
                                   rootResolver: FixtureProjectResolver(project: b), configurationReader: reader)
        let task = Task { await store.discoverConfiguration() }
        while !(await reader.started) { await Task.yield() }
        await store.addProject(at: b.rootDirectory)
        await reader.finish()
        await task.value
        XCTAssertEqual(store.project, b)
        XCTAssertNil(store.discovery)
        XCTAssertFalse(store.isDiscovering)
    }

    func test_discovery_whenCancelled_shouldRestorePreviousReading() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let reader = DelayedConfigurationFixture()
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(), configurationReader: reader)
        let task = Task { await store.discoverConfiguration() }
        while !(await reader.started) { await Task.yield() }
        task.cancel()
        await reader.finish()
        await task.value
        XCTAssertNil(store.discovery)
        XCTAssertFalse(store.isDiscovering)
    }

    func test_discovery_whenFIFO_shouldRejectWithoutBlocking() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("package.json").path, 0o600), 0)
        let result = try await LocalProjectConfigurationReader().read(root: directory)
        XCTAssertEqual(result.issues.first?.failure.kind, .invalidOutput)
    }

    func test_commonEditor_shouldPersistChosenApplicationWithoutPickerAndKeepOtherProjects() async throws {
        let a = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let b = try testProject(URL(fileURLWithPath: "/private/tmp/b"))
        let store = WorkspaceStore(project: a, provider: PreviewWorkspaceSnapshotProvider(), rootResolver: FixtureProjectResolver(project: b))
        await store.addProject(at: b.rootDirectory)
        let opener = ActionOpenerFixture()
        let apps = ApplicationLocatorFixture(choice: editor)
        let controller = ProjectActionsController(opener: opener, applications: apps)
        controller.reloadApplications()
        XCTAssertNotNil(controller.installedEditors[.visualStudioCode])
        await controller.openCommonEditor(.visualStudioCode, project: a, store: store)
        XCTAssertEqual(opener.choices, 0)
        XCTAssertEqual(opener.opened, [a.rootDirectory])
        XCTAssertEqual(store.preferences(for: a.id).editor, editor)
        XCTAssertNil(store.preferences(for: b.id).editor)
        controller.folder(a.rootDirectory)
        await controller.terminal(a.rootDirectory)
        XCTAssertEqual(store.preferences(for: a.id).editor, editor)
        apps.choice = nil
        await controller.openCommonEditor(.visualStudioCode, project: a, store: store)
        XCTAssertEqual(controller.feedbackKey, "actions.error.missingApplication")
        XCTAssertEqual(opener.opened.count, 1)
    }

    private var editor: ProjectEditor {
        ProjectEditor(bundleIdentifier: "example.editor", applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"), name: "Editor")
    }
    private var link: ProjectLink { ProjectLink(name: "API", url: URL(string: "http://localhost:8080/docs")!) }
}

@MainActor
private final class ActionOpenerFixture: ProjectActionOpening {
    var choice: ProjectEditor?
    var choices = 0
    var opened: [URL] = []
    var error: (any Error)?
    var onChoose: (() -> Void)?
    func chooseEditor() async throws -> ProjectEditor? { choices += 1; onChoose?(); return choice }
    func openProject(_ root: URL, editor: ProjectEditor) async throws { if let error { throw error }; opened.append(root) }
    func openTerminal(_ root: URL) async throws { }
    func openFolder(_ root: URL) throws { }
    func revealConfiguration(_ name: String, root: URL) throws { }
    func openLink(_ url: URL) throws { }
    func copy(_ text: String) throws { }
}

private actor ConfigurationFixture: ProjectConfigurationReading {
    var results: [Result<ProjectDiscovery, LocalReadFailure>]
    init(results: [Result<ProjectDiscovery, LocalReadFailure>]) { self.results = results }
    func read(root: URL) async throws -> ProjectDiscovery { try results.removeFirst().get() }
}

private actor DelayedConfigurationFixture: ProjectConfigurationReading {
    private var continuation: CheckedContinuation<ProjectDiscovery, Never>?
    var started: Bool { continuation != nil }
    func read(root: URL) async throws -> ProjectDiscovery {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: ProjectDiscovery()); continuation = nil }
}

@MainActor
private final class ApplicationLocatorFixture: ProjectApplicationLocating {
    var choice: ProjectEditor?
    init(choice: ProjectEditor?) { self.choice = choice }
    func editor(_ kind: CommonProjectEditor) -> ProjectEditor? { choice }
}
