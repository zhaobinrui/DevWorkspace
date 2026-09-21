import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class ProjectWorkspaceTests: XCTestCase {
    func test_addAndSelect_whenRelaunched_shouldRestoreSelectedProjectWithoutDuplicates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try testProject(directory.appendingPathComponent("a"))
        let b = try testProject(directory.appendingPathComponent("b"))
        let repository = FileProjectCatalogRepository(fileURL: directory.appendingPathComponent("settings/projects.json"))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository, rootResolver: FixtureProjectResolver(project: a))
        await store.addProject(at: a.rootDirectory)
        await store.addProject(at: a.rootDirectory)
        XCTAssertEqual(store.catalog.projects.count, 1)
        var catalog = try repository.load()
        catalog.projects.append(b)
        try repository.save(catalog)
        store.reloadCatalog()
        store.selectProject(b.id)
        let restored = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        XCTAssertEqual(restored.project, b)
        XCTAssertEqual(restored.catalog.projects.count, 2)
        XCTAssertEqual(restored.state, .idle)
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_catalog_whenCorrupt_shouldKeepFileAndBlockAccidentalOverwrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json")
        let original = Data("broken {".utf8)
        try original.write(to: file)
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: FileProjectCatalogRepository(fileURL: file))
        XCTAssertTrue(store.catalogLoadBlocked)
        XCTAssertEqual(store.projectIssue?.kind, .corruptStorage)
        await store.addProject(at: directory)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertNil(store.project)
        try JSONEncoder().encode(ProjectCatalog()).write(to: file)
        store.reloadCatalog()
        XCTAssertFalse(store.catalogLoadBlocked)
        XCTAssertNil(store.projectIssue)
    }

    func test_catalog_whenNewerVersion_shouldRefuseToRewrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json")
        var catalog = ProjectCatalog(); catalog.version = 99
        try JSONEncoder().encode(catalog).write(to: file)
        XCTAssertThrowsError(try FileProjectCatalogRepository(fileURL: file).load()) { error in
            XCTAssertEqual((error as? LocalReadFailure)?.kind, .unsupportedVersion)
        }
    }

    func test_selection_whenSaveFails_shouldKeepPreviousSelectionAndShowPermissionError() throws {
        let a = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let b = try testProject(URL(fileURLWithPath: "/private/tmp/b"))
        let repository = FailingSaveRepository(catalog: ProjectCatalog(projects: [a, b], selectedID: a.id))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        store.selectProject(b.id)
        XCTAssertEqual(store.project, a)
        XCTAssertEqual(store.projectIssue?.kind, .permissionDenied)
    }

    func test_add_whenIdentityHasMoved_shouldRequireExplicitResolution() async throws {
        let metadata = UUID()
        let a = try testProject(URL(fileURLWithPath: "/private/tmp/a"), id: metadata)
        let moved = try testProject(URL(fileURLWithPath: "/private/tmp/moved"), id: metadata)
        let store = WorkspaceStore(project: a, provider: PreviewWorkspaceSnapshotProvider(), rootResolver: FixtureProjectResolver(project: moved))
        await store.addProject(at: moved.rootDirectory)
        XCTAssertEqual(store.project, a)
        XCTAssertEqual(store.catalog.projects, [a])
        XCTAssertEqual(store.projectIssue?.kind, .identityConflict)
        store.confirmRelocation()
        XCTAssertEqual(store.project?.id, a.id)
        XCTAssertEqual(store.project?.rootDirectory, moved.rootDirectory)
        XCTAssertEqual(store.catalog.projects.count, 1)
    }

    func test_rootResolver_whenInvalidOrNonLocal_shouldReject() async {
        for directory in [URL(string: "https://example.invalid/project")!, URL(fileURLWithPath: "/private/tmp/absent-\(UUID())")] {
            do { _ = try await LocalProjectRootResolver().project(at: directory); XCTFail("Expected invalid directory") }
            catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .invalidDirectory) }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func test_attribution_whenPathsOverlap_shouldUseDirectoryBoundariesAndMostSpecificProject() throws {
        let outer = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let nested = try testProject(URL(fileURLWithPath: "/private/tmp/project/nested"))
        let resolve: (String) -> ProcessAttribution = { path in
            ProjectAttributionResolver.resolve(testProcess(directory: path), projects: [outer, nested], bindings: [])
        }
        XCTAssertEqual(resolve("/private/tmp/project/src"), .directory(outer.id))
        XCTAssertEqual(resolve("/private/tmp/project/nested/src"), .directory(nested.id))
        XCTAssertEqual(resolve("/private/tmp/project-other"), .unassigned)
        XCTAssertEqual(ProjectAttributionResolver.resolve(testProcess(directory: nil), projects: [outer], bindings: []), .unassigned)
    }

    func test_attribution_whenPIDIsReused_shouldNotReusePersistedConfirmation() throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let previous = testProcess(start: 1, directory: nil)
        let replacement = testProcess(start: 2, directory: nil)
        let bindings = [ProcessProjectBinding(process: previous.identity, projectID: project.id)]
        XCTAssertEqual(ProjectAttributionResolver.resolve(previous, projects: [project], bindings: bindings), .manual(project.id))
        XCTAssertEqual(ProjectAttributionResolver.resolve(replacement, projects: [project], bindings: bindings), .unassigned)
    }

    func test_partialRefresh_whenGitFails_shouldKeepGitTimestampAndPublishNewPorts() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let old = Date(timeIntervalSince1970: 100)
        let fresh = Date(timeIntervalSince1970: 200)
        let git = GitSummary(branch: "main", changedFileCount: 2, commitsAhead: 0, commitsBehind: 0)
        let first = observation(project, git: .success(git, at: old), ports: .success([testProcess()], at: old))
        let second = observation(project, git: .failed(LocalReadFailure(kind: .permissionDenied), at: fresh), ports: .success([], at: fresh))
        let third = observation(project, git: .success(git, at: fresh), ports: .success([], at: fresh))
        let store = WorkspaceStore(project: project, provider: SequenceObservationProvider([first, second, third]))
        await store.refresh(); await store.refresh()
        XCTAssertEqual(store.currentSnapshot?.readings?.git.value, git)
        XCTAssertEqual(store.currentSnapshot?.readings?.git.checkedAt, old)
        XCTAssertEqual(store.currentSnapshot?.readings?.git.attemptedAt, fresh)
        XCTAssertEqual(store.currentSnapshot?.readings?.git.failure?.kind, .permissionDenied)
        XCTAssertEqual(store.currentSnapshot?.readings?.ports.checkedAt, fresh)
        XCTAssertEqual(store.currentSnapshot?.readings?.ports.value, [])
        guard case .degraded = store.state else { return XCTFail("Expected partial failure") }
        await store.refresh()
        guard case .ready = store.state else { return XCTFail("Expected recovery") }
    }

    func test_partialRefresh_whenPortsFail_shouldKeepPortsButRefreshGit() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let old = Date(timeIntervalSince1970: 100)
        let first = observation(project, git: .success(nil, at: old), ports: .success([testProcess()], at: old))
        let second = observation(project, git: .success(nil), ports: .failed(LocalReadFailure(kind: .timedOut)))
        let store = WorkspaceStore(project: project, provider: SequenceObservationProvider([first, second]))
        await store.refresh(); await store.refresh()
        XCTAssertEqual(store.projectProcesses.count, 1)
        XCTAssertEqual(store.currentSnapshot?.readings?.ports.checkedAt, old)
        XCTAssertNil(store.currentSnapshot?.readings?.git.failure)
        XCTAssertEqual(store.currentSnapshot?.readings?.ports.failure?.kind, .timedOut)
    }

    func test_selection_whenOldRefreshFinishesLate_shouldNotReplaceNewProject() async throws {
        let a = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let b = try testProject(URL(fileURLWithPath: "/private/tmp/b"))
        let provider = DelayedObservationProvider()
        let store = WorkspaceStore(project: a, provider: provider, rootResolver: FixtureProjectResolver(project: b))
        let refresh = Task { await store.refresh() }
        await provider.waitUntilStarted()
        await store.addProject(at: b.rootDirectory)
        await provider.finish(observation(a, git: .success(nil), ports: .success([])))
        await refresh.value
        XCTAssertEqual(store.project, b)
        XCTAssertNil(store.currentSnapshot)
        XCTAssertEqual(store.state, .idle)
    }

    func test_binding_whenLiveIdentityChanged_shouldRefuseConfirmation() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/project"))
        let displayed = testProcess(start: 1)
        let replaced = testProcess(start: 2)
        let store = WorkspaceStore(project: project,
                                   provider: SequenceObservationProvider([observation(project, git: .success(nil), ports: .success([displayed]))]),
                                   processInspector: FixtureProcessInspector(process: replaced))
        await store.refresh()
        await store.bind(displayed, to: project.id)
        XCTAssertTrue(store.catalog.bindings.isEmpty)
        XCTAssertEqual(store.projectIssue?.kind, .processChanged)
    }

    func test_removeProject_whenConfirmed_shouldClearItsBindingsAndRestoreRemainingSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try testProject(directory)
        let repository = FileProjectCatalogRepository(fileURL: directory.appendingPathComponent("projects.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id,
                                          bindings: [ProcessProjectBinding(process: testProcess().identity, projectID: project.id)]))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        store.removeSelectedProject()
        XCTAssertNil(store.project)
        XCTAssertTrue(try repository.load().bindings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }
}

struct FixtureProjectResolver: ProjectRootResolving {
    let project: ProjectReference
    func project(at directory: URL) async throws -> ProjectReference { project }
}

struct FailingSaveRepository: ProjectCatalogPersisting {
    let catalog: ProjectCatalog
    func load() throws -> ProjectCatalog { catalog }
    func save(_ catalog: ProjectCatalog) throws { throw LocalReadFailure(kind: .permissionDenied) }
}

actor SequenceObservationProvider: WorkspaceSnapshotProviding {
    private var values: [WorkspaceSnapshot]
    init(_ values: [WorkspaceSnapshot]) { self.values = values }
    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot { values.removeFirst() }
}

actor DelayedObservationProvider: WorkspaceSnapshotProviding {
    private var continuation: CheckedContinuation<WorkspaceSnapshot, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ value: WorkspaceSnapshot) { continuation?.resume(returning: value); continuation = nil }
}

func observation(_ project: ProjectReference, git: SourceReading<GitSummary>, ports: SourceReading<[ListeningProcess]>) -> WorkspaceSnapshot {
    WorkspaceSnapshot(project: project, lifecycle: .observed, git: git.value, services: [], observedAt: .now,
                      freshness: .current, origin: .local, readings: WorkspaceReadings(git: git, ports: ports))
}
