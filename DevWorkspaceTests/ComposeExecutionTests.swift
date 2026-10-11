import Darwin
import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class ComposeExecutionTests: XCTestCase {
    private let fullID = String(repeating: "a", count: 64)

    func test_workspace_whenComposeAndNodeAreTrusted_shouldStartInOrderAndStopBoth() async throws {
        guard let npm = NPMExecutableResolver.resolve() else { throw XCTSkip("npm is required") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try availablePort()
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        let script = "require('http').createServer((q,r)=>{r.writeHead(200);r.end('ready')}).listen(\(port),'127.0.0.1')"
        try Data(script.utf8).write(to: root.appendingPathComponent("server.js"))
        try Data("{\"scripts\":{\"dev\":\"node server.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = ComposeControlFixture(id: fullID)
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   npmExecutable: npm, composeController: controller)
        await store.discoverConfiguration()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")],
            composeConfigurationName: "compose.yaml", processReadinessURL: url)
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
            packageDigest: store.discovery?.value?.packageDigest,
            composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedWorkspace()
        for _ in 0..<150 {
            if store.workspacePhase == .ready { break }
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reached = store.workspacePhase
        let readyURL = store.readyPrimaryURL
        store.stopSelectedWorkspace()
        for _ in 0..<100 {
            if store.workspacePhase == .stopped { break }
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(reached, .ready)
        XCTAssertEqual(readyURL, url)
        XCTAssertEqual(store.workspacePhase, .stopped)
        XCTAssertNil(store.managedProcess)
        XCTAssertNil(store.managedComposeRun)
        let stopped = await controller.stoppedIDs
        XCTAssertEqual(stopped, [fullID])
    }

    func test_workspace_whenNodeFailsAfterComposeStart_shouldRollbackOnlyNewCompose() async throws {
        guard let npm = NPMExecutableResolver.resolve() else { throw XCTSkip("npm is required") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try availablePort()
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        try Data("{\"scripts\":{\"dev\":\"node -e 'process.exit(2)'\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = ComposeControlFixture(id: fullID)
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   readinessTimeout: .milliseconds(300), npmExecutable: npm,
                                   composeController: controller)
        await store.discoverConfiguration()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")],
            composeConfigurationName: "compose.yaml", processReadinessURL: url)
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
            packageDigest: store.discovery?.value?.packageDigest,
            composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedWorkspace()
        for _ in 0..<150 {
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.workspacePhase, .failed(.applicationNotReady))
        XCTAssertNil(store.managedProcess)
        XCTAssertNil(store.managedComposeRun)
        let stopped = await controller.stoppedIDs
        XCTAssertEqual(stopped, [fullID])
        XCTAssertTrue(try repository.load().pendingComposeStarts.isEmpty)
    }

    func test_pendingComposeStart_whenAppRestarts_shouldRecoverOnlyNewContainer() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        let pending = PendingComposeStart(projectID: project.id, rootDirectory: root,
            configurationName: "compose.yaml", configurationDigest: String(repeating: "b", count: 64),
            baselineContainerIDs: [], createdAt: .now)
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id,
                                           pendingComposeStarts: [pending]))
        let controller = ComposeControlFixture(id: fullID, initialRunning: true)
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   composeController: controller)
        XCTAssertEqual(store.composePhase, .recoveryRequired)
        store.startSelectedCompose()
        XCTAssertEqual(store.composePhase, .recoveryRequired)
        store.recoverPendingComposeStart()
        for _ in 0..<100 where store.managedComposeRun == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.managedComposeRun?.containerIDs, [fullID])
        XCTAssertTrue(try repository.load().pendingComposeStarts.isEmpty)
        store.stopSelectedCompose()
        for _ in 0..<100 where store.composePhase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .stopped)
        let stopped = await controller.stoppedIDs
        XCTAssertEqual(stopped, [fullID])
    }

    func test_compose_whenTrusted_shouldStartVerifyHealthAndStopExactContainer() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = ComposeControlFixture(id: fullID)
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedCompose()
        for _ in 0..<100 {
            if store.composePhase == .ready { break }
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .ready)
        XCTAssertEqual(store.managedComposeRun?.containerIDs, [fullID])
        // A changed file must revoke future starts without stranding this exact,
        // previously attributed container when the user requests a safe stop.
        try Data("services: {web: {image: changed}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        store.stopSelectedCompose()
        for _ in 0..<100 {
            if store.composePhase == .stopped { break }
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .stopped)
        XCTAssertNil(store.managedComposeRun)
        let stopped = await controller.stoppedIDs
        XCTAssertEqual(stopped, [fullID])
    }

    func test_compose_whenSourceChangesAfterTrust_shouldRefuseBeforeDocker() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("compose.yaml")
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8).write(to: file)
        let project = try testProject(root)
        let controller = ComposeControlFixture(id: fullID)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        try Data("services: {web: {image: changed}}".utf8).write(to: file)
        store.startSelectedCompose()
        for _ in 0..<100 {
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .failed(.sourceChanged))
        let didStart = await controller.didStart
        XCTAssertFalse(didStart)
    }

    func test_compose_whenStartIsRunning_shouldBlockProjectSwitchUntilIdentityIsRecorded() async throws {
        let root = try temporaryDirectory()
        let otherRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        let project = try testProject(root)
        let other = try testProject(otherRoot)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project, other], selectedID: project.id))
        let controller = ComposeControlFixture(id: fullID, startDelay: .milliseconds(250))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedCompose()
        for _ in 0..<50 where store.composePhase != .starting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.composePhase, .starting)
        store.selectProject(other.id)
        XCTAssertEqual(store.project?.id, project.id)
        XCTAssertEqual(store.projectIssue?.kind, .operationInProgress)
        for _ in 0..<100 where store.composePhase != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .ready)
        store.stopSelectedCompose()
        for _ in 0..<100 where store.composePhase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .stopped)
        store.selectProject(other.id)
        XCTAssertEqual(store.project?.id, other.id)
    }

    func test_compose_whenCancelledDuringStart_shouldNotLeaveAnUntrackedRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        let project = try testProject(root)
        let controller = ComposeControlFixture(id: fullID, startDelay: .seconds(5))
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedCompose()
        for _ in 0..<50 where store.composePhase != .starting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.composePhase, .starting)
        store.cancelSelectedComposeStart()
        for _ in 0..<100 where store.composePhase != .cancelled {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .cancelled)
        XCTAssertNil(store.managedComposeRun)
        let didStart = await controller.didStart
        XCTAssertFalse(didStart)
    }

    func test_compose_whenPartiallyStartedThenFailed_shouldRetainExactIDsForRecovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        let project = try testProject(root)
        let controller = ComposeControlFixture(id: fullID, failAfterStart: true)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedCompose()
        for _ in 0..<100 {
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .failed(.commandFailed))
        XCTAssertEqual(store.managedComposeRun?.containerIDs, [fullID])
        store.stopSelectedCompose()
        for _ in 0..<100 where store.composePhase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .stopped)
        XCTAssertNil(store.managedComposeRun)
    }

    func test_compose_whenReadinessTimesOut_shouldRetainRunAndAllowRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("services: {web: {image: caddy:2.11.4-alpine}}".utf8)
            .write(to: root.appendingPathComponent("compose.yaml"))
        let project = try testProject(root)
        let controller = ComposeControlFixture(id: fullID, initialHealth: nil)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   readinessTimeout: .milliseconds(100), composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        store.startSelectedCompose()
        for _ in 0..<100 {
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .failed(.readinessTimedOut))
        XCTAssertEqual(store.managedComposeRun?.containerIDs, [fullID])
        await controller.setHealth(.healthy)
        store.retryComposeReadiness()
        for _ in 0..<100 where store.composePhase != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .ready)
        store.stopSelectedCompose()
        for _ in 0..<100 where store.composePhase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .stopped)
    }

    func test_compose_whenAppRestarts_shouldRecoverRecordedContainerForSafeStop() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let record = ManagedComposeRun(projectID: project.id, rootDirectory: root,
                                       configurationName: "compose.yaml", configurationDigest: String(repeating: "a", count: 64),
                                       containerIDs: [fullID], launchedAt: .now)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id,
                                           managedComposeRuns: [record]))
        let controller = ComposeControlFixture(id: fullID, initialRunning: true)
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   composeController: controller)
        XCTAssertEqual(store.composePhase, .recoveryRequired)
        store.stopSelectedCompose()
        for _ in 0..<100 where store.composePhase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.composePhase, .stopped)
        XCTAssertNil(store.managedComposeRun)
    }

    func test_liveCompose_whenExplicitlyEnabled_shouldStartReadyAndStop() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp/DevWorkspaceComposeControlAcceptance")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Live Compose control acceptance is explicitly opt-in")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "devworkspace-acceptance-" + UUID().uuidString.prefix(8).lowercased()
        let port = try availablePort()
        let contents = """
        name: \(name)
        services:
          web:
            image: caddy:2.11.4-alpine
            command: ["caddy", "file-server", "--listen", ":80", "--root", "/usr/share/caddy"]
            ports:
              - "127.0.0.1:\(port):80"
        """
        try Data(contents.utf8).write(to: root.appendingPathComponent("compose.yaml"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = LocalDockerComposeController()
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   readinessTimeout: .seconds(20), composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "compose.yaml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        var preferences = store.preferences(for: project.id)
        preferences.links = [ProjectLink(name: "HTTP", url: URL(string: "http://127.0.0.1:\(port)/")!)]
        try store.savePreferences(preferences)
        store.startSelectedCompose()
        for _ in 0..<200 {
            if store.composePhase == .ready { break }
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reached = store.composePhase
        store.stopSelectedCompose()
        for _ in 0..<150 {
            if store.composePhase == .stopped { break }
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let status = try? await controller.read(root: root),
           !status.containers.filter({ $0.state == .running }).isEmpty {
            // A failed persistence path must not leak an isolated acceptance container.
            try await controller.stop(root: root, configurationName: "compose.yaml",
                                      containerIDs: status.containers.filter { $0.state == .running }.map(\.id))
        }
        XCTAssertEqual(reached, .ready)
        XCTAssertEqual(store.composePhase, .stopped)
        XCTAssertNil(store.managedComposeRun)
    }

    func test_liveBackendCompose_whenExplicitlyEnabled_shouldControlAllFourServices() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp/DevWorkspaceBackendComposeAcceptance")
        guard let data = try? Data(contentsOf: marker),
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/private/tmp/devworkspace-backend-acceptance.") else {
            throw XCTSkip("The isolated backend Compose acceptance is explicitly opt-in")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("docker-compose.yml").path) else {
            throw XCTSkip("Isolated backend Compose copy is unavailable")
        }
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = LocalDockerComposeController()
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   readinessTimeout: .seconds(120), composeController: controller)
        await store.discoverConfiguration()
        let draft = ProjectProfile(composeConfigurationName: "docker-compose.yml")
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil,
                                     composeDigest: store.discovery?.value?.composeDigest)
        var preferences = store.preferences(for: project.id)
        preferences.links = [ProjectLink(name: "Elasticsearch HTTP", url: URL(string: "http://127.0.0.1:19200/")!)]
        try store.savePreferences(preferences)
        store.startSelectedCompose()
        for _ in 0..<150 {
            if store.composePhase == .ready { break }
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .seconds(1))
        }
        let reached = store.composePhase
        let serviceNames = try await controller.read(root: root)?.containers
            .filter { $0.state == .running }.map(\.serviceName)
        if store.managedComposeRun != nil {
            store.stopSelectedCompose()
            for _ in 0..<60 {
                if store.composePhase == .stopped { break }
                if case .failed = store.composePhase { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        XCTAssertEqual(reached, .ready, "All four actual backend dependencies must reach the configured HTTP gate")
        XCTAssertEqual(Set(serviceNames ?? []), Set(["postgres", "redis", "elasticsearch", "minio"]))
        XCTAssertEqual(store.composePhase, .stopped)
        XCTAssertNil(store.managedComposeRun)
    }

    func test_liveBackendJava_whenExplicitlyEnabled_shouldStartAfterComposeAndStopInReverse() async throws {
        struct Configuration: Decodable {
            let root: String
            let javaExecutable: String
            let jarPath: String
        }
        let marker = URL(fileURLWithPath: "/private/tmp/DevWorkspaceBackendJavaAcceptance")
        guard let data = try? Data(contentsOf: marker),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              configuration.root.hasPrefix("/private/tmp/devworkspace-backend-java-acceptance."),
              configuration.javaExecutable.hasPrefix("/"),
              configuration.jarPath.hasPrefix("/") else {
            throw XCTSkip("The isolated backend Java acceptance is explicitly opt-in")
        }
        let root = URL(fileURLWithPath: configuration.root, isDirectory: true)
        let java = URL(fileURLWithPath: configuration.javaExecutable)
        let jar = URL(fileURLWithPath: configuration.jarPath)
        guard FileManager.default.isExecutableFile(atPath: java.path),
              FileManager.default.fileExists(atPath: jar.path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("docker-compose.yml").path),
              ![root.path, java.path, jar.path].contains(where: { $0.contains(" ") || $0.contains("'") }) else {
            throw XCTSkip("Isolated backend runtime artifacts are unavailable")
        }
        let command = "PG_URL=jdbc:postgresql://127.0.0.1:15433/knowledge_vault "
            + "REDIS_PORT=16379 ES_URIS=http://127.0.0.1:19200 "
            + "MINIO_ENDPOINT=http://127.0.0.1:19000 SYNC_MAINTENANCE_ENABLED=false "
            + "ASSET_SEARCH_WORKER_ENABLED=false RAG_WORKER_ENABLED=false "
            + "INITIAL_USER_ENABLED=false SMS_AUTH_ENABLED=false "
            + "\(java.path) -jar \(jar.path) --spring.profiles.active=dev --server.port=18080"
        let package = ["scripts": ["dev": command]]
        try JSONSerialization.data(withJSONObject: package)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = LocalDockerComposeController()
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   readinessTimeout: .seconds(120), composeController: controller)
        await store.discoverConfiguration()
        let composeURL = URL(string: "http://127.0.0.1:19200/")!
        let javaURL = URL(string: "http://127.0.0.1:18080/actuator/health")!
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")],
                                   composeConfigurationName: "docker-compose.yml",
                                   processReadinessURL: javaURL, composeReadinessURL: composeURL)
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest,
                                     composeDigest: store.discovery?.value?.composeDigest)
        var preferences = store.preferences(for: project.id)
        preferences.links = [ProjectLink(name: "Backend health", url: javaURL),
                             ProjectLink(name: "Elasticsearch", url: composeURL)]
        try store.savePreferences(preferences)
        store.startSelectedCompose()
        for _ in 0..<150 {
            if store.composePhase == .ready { break }
            if case .failed = store.composePhase { break }
            try await Task.sleep(for: .seconds(1))
        }
        let composeReached = store.composePhase
        if composeReached == .ready {
            try await Task.sleep(for: .milliseconds(200))
            store.startSelectedProject()
            for _ in 0..<150 {
                if store.executionPhase == .ready { break }
                if case .failed = store.executionPhase { break }
                try await Task.sleep(for: .seconds(1))
            }
        }
        let processReached = store.executionPhase
        if store.managedProcess != nil {
            store.stopSelectedProject()
            for _ in 0..<60 {
                if store.executionPhase == .stopped { break }
                if case .failed = store.executionPhase { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        if store.managedComposeRun != nil {
            try await Task.sleep(for: .milliseconds(200))
            store.stopSelectedCompose()
            for _ in 0..<60 {
                if store.composePhase == .stopped { break }
                if case .failed = store.composePhase { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        XCTAssertEqual(composeReached, .ready)
        XCTAssertEqual(processReached, .ready)
        XCTAssertEqual(store.executionPhase, .stopped)
        XCTAssertEqual(store.composePhase, .stopped)
        XCTAssertNil(store.managedProcess)
        XCTAssertNil(store.managedComposeRun)
    }

    func test_liveBackendNativeJava_whenExplicitlyEnabled_shouldOneClickStartAndStop() async throws {
        struct Configuration: Decodable {
            let root: String
            let javaExecutable: String
            let jarSource: String
        }
        let marker = URL(fileURLWithPath: "/private/tmp/DevWorkspaceBackendNativeAcceptance")
        guard let data = try? Data(contentsOf: marker),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              configuration.root.hasPrefix("/private/tmp/devworkspace-backend-acceptance."),
              configuration.javaExecutable.hasPrefix("/"),
              configuration.jarSource.hasSuffix(".jar") else {
            throw XCTSkip("The isolated backend native-Java acceptance is explicitly opt-in")
        }
        let root = URL(fileURLWithPath: configuration.root, isDirectory: true)
        let archive = root.appendingPathComponent("app.jar")
        let configDirectory = root.appendingPathComponent("config")
        let source = URL(fileURLWithPath: configuration.jarSource)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("docker-compose.yml").path),
              FileManager.default.isExecutableFile(atPath: configuration.javaExecutable),
              FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: archive.path),
              !FileManager.default.fileExists(atPath: configDirectory.path) else {
            throw XCTSkip("Isolated backend inputs are unavailable or already in use")
        }
        try FileManager.default.copyItem(at: source, to: archive)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let overrides = """
        spring:
          datasource:
            url: jdbc:postgresql://127.0.0.1:15433/knowledge_vault
            username: knowledgevault
            password: devworkspace-isolated-postgres
          data:
            redis:
              host: 127.0.0.1
              port: 16379
              password: devworkspace-isolated-redis
          elasticsearch:
            uris: http://127.0.0.1:19200
        knowledge-vault:
          storage:
            s3:
              endpoint: http://127.0.0.1:19000
              access-key: devworkspace-isolated-minio
              secret-key: devworkspace-isolated-minio-password
          sync:
            maintenance:
              enabled: false
          infrastructure:
            monitor:
              enabled: false
          search:
            worker:
              enabled: false
          rag:
            worker:
              enabled: false
          security:
            initial-user:
              enabled: false
            sms:
              enabled: false
        """
        try Data(overrides.utf8).write(to: configDirectory.appendingPathComponent("application-dev.yml"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("native-catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let controller = LocalDockerComposeController()
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   readinessTimeout: .seconds(120), composeController: controller)
        await store.discoverConfiguration()
        let java = ProfileJavaArchive(relativePath: "app.jar", executablePath: configuration.javaExecutable,
                                      springProfile: "dev", serverPort: 18080)
        let profile = ProjectProfile(composeConfigurationName: "docker-compose.yml",
            processReadinessURL: URL(string: "http://127.0.0.1:18080/actuator/health")!,
            composeReadinessURL: URL(string: "http://127.0.0.1:19200/")!, javaArchive: java)
        try store.saveProfileDraft(profile, for: project.id)
        await store.refreshJavaArchiveSource()
        try await store.trustProfile(for: project.id, reviewed: profile, packageDigest: nil,
            composeDigest: store.discovery?.value?.composeDigest,
            javaDigest: store.javaArchiveSource?.value?.digest)
        store.startSelectedWorkspace()
        for _ in 0..<150 {
            if store.workspacePhase == .ready { break }
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .seconds(1))
        }
        let reached = store.workspacePhase
        let readyURL = store.readyPrimaryURL
        store.stopSelectedWorkspace()
        for _ in 0..<120 {
            if store.workspacePhase == .stopped { break }
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(reached, .ready)
        XCTAssertEqual(readyURL, profile.processReadinessURL)
        XCTAssertEqual(store.workspacePhase, .stopped)
        XCTAssertNil(store.managedProcess)
        XCTAssertNil(store.managedComposeRun)
    }

    private func availablePort() throws -> UInt16 {
        let listener = try LocalAcceptancePort.reserve()
        defer { Darwin.close(listener.fd) }
        return listener.port
    }
}

private actor ComposeControlFixture: DockerComposeControlling {
    let id: String
    let startDelay: Duration
    let failAfterStart: Bool
    private var running = false
    private var health: ComposeContainerHealth?
    private(set) var didStart = false
    private(set) var stoppedIDs: [String] = []

    init(id: String, startDelay: Duration = .zero, initialRunning: Bool = false,
         initialHealth: ComposeContainerHealth? = .healthy, failAfterStart: Bool = false) {
        self.id = id
        self.startDelay = startDelay
        self.running = initialRunning
        self.didStart = initialRunning
        self.health = initialHealth
        self.failAfterStart = failAfterStart
    }

    func setHealth(_ value: ComposeContainerHealth?) { health = value }

    func read(root: URL) async throws -> ComposeProjectStatus? {
        let containers = didStart
            ? [ComposeContainer(id: id, projectName: "sample", serviceName: "web",
                                state: running ? .running : .exited,
                                health: running ? health : nil, ports: [])]
            : []
        return ComposeProjectStatus(configurationName: "compose.yaml", projectName: "sample", containers: containers)
    }

    func start(root: URL, configurationName: String) async throws {
        try await Task.sleep(for: startDelay)
        didStart = true
        running = true
        if failAfterStart { throw LocalReadFailure(kind: .unavailable) }
    }

    func stop(root: URL, configurationName: String, containerIDs: [String]) async throws {
        guard containerIDs == [id] else { throw LocalReadFailure(kind: .dockerAttributionUncertain) }
        stoppedIDs = containerIDs
        running = false
    }
}

private enum LocalAcceptancePort {
    static func reserve() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalReadFailure(kind: .unavailable) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { Darwin.close(fd); throw LocalReadFailure(kind: .unavailable) }
        let retrieved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard retrieved == 0 else { Darwin.close(fd); throw LocalReadFailure(kind: .unavailable) }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}
