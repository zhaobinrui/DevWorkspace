import Darwin
import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class ProjectExecutionTests: XCTestCase {
    func test_safety_whenPIDPathOwnerOrDirectoryChanges_shouldRefuseStop() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let identity = ProcessIdentity(pid: 123, userID: getuid(), executablePath: "/bin/node",
                                       startedSeconds: 1, startedMicroseconds: 2)
        let record = ManagedProjectProcess(projectID: project.id, rootDirectory: root,
                                           scriptName: "dev", identity: identity, launchedAt: .now)
        let matching = InspectedProcess(identity: identity, workingDirectory: root, directoryFailure: nil)
        XCTAssertTrue(ManagedProcessSafety.isSameOwnedProjectProcess(matching, as: record,
                                                                     project: project, userID: getuid()))
        for changed in [ProcessIdentity(pid: 124, userID: getuid(), executablePath: "/bin/node",
                                        startedSeconds: 1, startedMicroseconds: 2),
                        ProcessIdentity(pid: 123, userID: getuid(), executablePath: "/bin/other",
                                        startedSeconds: 1, startedMicroseconds: 2),
                        ProcessIdentity(pid: 123, userID: getuid() + 1, executablePath: "/bin/node",
                                        startedSeconds: 1, startedMicroseconds: 2)] {
            XCTAssertFalse(ManagedProcessSafety.isSameOwnedProjectProcess(
                InspectedProcess(identity: changed, workingDirectory: root, directoryFailure: nil),
                as: record, project: project, userID: getuid()))
        }
        XCTAssertFalse(ManagedProcessSafety.isSameOwnedProjectProcess(
            InspectedProcess(identity: identity, workingDirectory: root.deletingLastPathComponent(), directoryFailure: nil),
            as: record, project: project, userID: getuid()))
    }

    func test_readiness_whenURLIsNotLoopback_shouldRejectBeforeNetwork() async throws {
        let reader = LoopbackHTTPReadinessProbe()
        XCTAssertFalse(LoopbackHTTPReadinessProbe.accepts(URL(string: "https://example.com:8080/health")!))
        XCTAssertFalse(LoopbackHTTPReadinessProbe.accepts(URL(string: "http://127.0.0.1:8080/health?token=x")!))
        XCTAssertTrue(LoopbackHTTPReadinessProbe.accepts(URL(string: "http://127.0.0.1:8080/health")!))
        do {
            _ = try await reader.probe(URL(string: "http://example.com:8080/health")!)
            XCTFail("Remote readiness probes must be rejected")
        } catch ProjectExecutionFailure.missingReadinessURL { }
    }

    func test_profile_whenReadinessTargetsChange_shouldRequireNewTrust() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let digest = String(repeating: "a", count: 64)
        let script = ProfileScriptCommand(role: .start, scriptName: "dev")
        let one = URL(string: "http://127.0.0.1:18080/health")!
        let two = URL(string: "http://127.0.0.1:19200/")!
        let profile = ProjectProfile(commands: [script], composeConfigurationName: "compose.yaml",
                                     processReadinessURL: one, composeReadinessURL: two)
        let original = try XCTUnwrap(profile.fingerprint(projectID: project.id, root: root,
                                                         packageDigest: digest, composeDigest: digest))
        var changed = profile
        changed.processReadinessURL = two
        XCTAssertNotEqual(changed.fingerprint(projectID: project.id, root: root,
                                              packageDigest: digest, composeDigest: digest), original)
        changed = profile
        changed.composeReadinessURL = one
        XCTAssertNotEqual(changed.fingerprint(projectID: project.id, root: root,
                                              packageDigest: digest, composeDigest: digest), original)
        changed = profile
        changed.processReadinessURL = URL(string: "https://example.com/health")
        XCTAssertFalse(changed.isValid())
    }

    func test_start_whenTrustedSourceChanges_shouldRefuseBeforeLaunching() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"scripts\":{\"dev\":\"node server.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        var preferences = store.preferences(for: project.id)
        preferences.links = [ProjectLink(name: "Health", url: URL(string: "http://127.0.0.1:8080/health")!)]
        try store.savePreferences(preferences)
        try Data("{\"scripts\":{\"dev\":\"node changed.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        store.startSelectedProject()
        for _ in 0..<100 {
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .failed(.sourceChanged))
        XCTAssertNil(store.managedProcess)
    }

    func test_liveECMProfile_whenExplicitlyEnabled_shouldReviewAndTrustWithoutExecution() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp/DevWorkspaceECMReadOnlyAcceptance")
        guard let data = try? Data(contentsOf: marker),
              let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasSuffix("/ecm-api") else {
            throw XCTSkip("Real ecm-api inspection is explicitly opt-in and read-only")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        await store.discoverConfiguration()
        guard let dev = store.discovery?.value?.packageScripts.first(where: { $0.name == "dev" }) else {
            XCTFail("Actual ecm-api dev script was not discovered")
            return
        }
        XCTAssertTrue(dev.body.contains("nodemon"))
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        XCTAssertEqual(store.profileTrustStatus(for: project), .trusted)
        XCTAssertEqual(store.executionPhase, .idle, "The real repository must not be executed")
        XCTAssertNil(store.managedProcess)
    }

    func test_restart_whenRecordedPIDIsGone_shouldClearStaleRecordWithoutSignal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let identity = ProcessIdentity(pid: Int32.max, userID: getuid(), executablePath: "/bin/node",
                                       startedSeconds: 1, startedMicroseconds: 0)
        let record = ManagedProjectProcess(projectID: project.id, rootDirectory: root,
                                           scriptName: "dev", identity: identity, launchedAt: .now)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id,
                                           managedProcesses: [record]))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        XCTAssertEqual(store.executionPhase, .recoveryRequired)
        store.stopSelectedProject()
        for _ in 0..<100 {
            if store.executionPhase == .stopped { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .stopped)
        XCTAssertNil(store.managedProcess)
        XCTAssertTrue(try repository.load().managedProcesses.isEmpty)
    }

    func test_stop_whenPIDWasReused_shouldDiscardRecordWithoutSignallingReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let identity = ProcessIdentity(pid: getpid(), userID: getuid(), executablePath: "/bin/node",
                                       startedSeconds: 1, startedMicroseconds: 0)
        let record = ManagedProjectProcess(projectID: project.id, rootDirectory: root,
                                           scriptName: "dev", identity: identity, launchedAt: .now)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id,
                                           managedProcesses: [record]))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        store.stopSelectedProject()
        for _ in 0..<100 {
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .failed(.identityUncertain))
        XCTAssertNil(store.managedProcess)
        XCTAssertTrue(try repository.load().managedProcesses.isEmpty)
    }

    func test_liveNodeProject_whenTrusted_shouldStartBecomeReadyAndStop() async throws {
        guard let npm = NPMExecutableResolver.resolve() else { throw XCTSkip("npm not installed") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try boundLoopbackSocket()
        close(listener.fd)
        let port = listener.port
        let script = "require('http').createServer((q,r)=>{r.writeHead(200);r.end('ready')}).listen(\(port),'127.0.0.1')"
        try Data(script.utf8).write(to: root.appendingPathComponent("server.js"))
        try Data("{\"scripts\":{\"dev\":\"node server.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   npmExecutable: npm)
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        var preferences = store.preferences(for: project.id)
        preferences.links = [ProjectLink(name: "Health", url: URL(string: "http://127.0.0.1:\(port)/")!)]
        try store.savePreferences(preferences)
        store.startSelectedProject()
        for _ in 0..<120 {
            if store.executionPhase == .ready { break }
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reached = store.executionPhase
        try Data("{\"scripts\":{\"dev\":\"node changed.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        store.stopSelectedProject()
        for _ in 0..<60 {
            if store.executionPhase == .stopped { break }
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(reached, .ready, "Actual Node project must pass HTTP readiness")
        XCTAssertEqual(store.executionPhase, .stopped, "Managed npm process must stop safely")
        XCTAssertNil(store.managedProcess)
    }

    func test_liveNodeProject_whenReadinessIsLate_shouldRetainIdentityAndAllowRetry() async throws {
        guard let npm = NPMExecutableResolver.resolve() else { throw XCTSkip("npm not installed") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try boundLoopbackSocket()
        close(listener.fd)
        let port = listener.port
        let script = "setTimeout(()=>require('http').createServer((q,r)=>{r.writeHead(200);r.end('ready')}).listen(\(port),'127.0.0.1'),1200)"
        try Data(script.utf8).write(to: root.appendingPathComponent("server.js"))
        try Data("{\"scripts\":{\"dev\":\"node server.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   readinessTimeout: .milliseconds(100), npmExecutable: npm)
        await store.discoverConfiguration()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")],
                                   processReadinessURL: url)
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        store.startSelectedProject()
        for _ in 0..<100 {
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .failed(.readinessTimedOut))
        XCTAssertNotNil(store.managedProcess)
        for _ in 0..<100 {
            if (try? await LoopbackHTTPReadinessProbe().probe(url)) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        store.retryReadiness()
        for _ in 0..<100 where store.executionPhase != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .ready)
        store.stopSelectedProject()
        for _ in 0..<100 where store.executionPhase != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .stopped)
        XCTAssertNil(store.managedProcess)
    }

    func test_liveJavaProject_whenTrustedWrapper_shouldStartBecomeReadyAndStop() async throws {
        guard let npm = NPMExecutableResolver.resolve(),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/javac") else {
            throw XCTSkip("npm or Java compiler unavailable")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try boundLoopbackSocket()
        close(listener.fd)
        let port = listener.port
        let source = """
        import com.sun.net.httpserver.HttpServer;
        import java.net.InetSocketAddress;
        public class Server {
          public static void main(String[] args) throws Exception {
            HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", \(port)), 0);
            server.createContext("/", exchange -> {
              byte[] body = "ready".getBytes("UTF-8");
              exchange.sendResponseHeaders(200, body.length);
              exchange.getResponseBody().write(body);
              exchange.close();
            });
            server.start();
          }
        }
        """
        try Data(source.utf8).write(to: root.appendingPathComponent("Server.java"))
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/javac")
        compiler.arguments = ["Server.java"]
        compiler.currentDirectoryURL = root
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw XCTSkip("Java compiler failed") }
        try Data("{\"scripts\":{\"dev\":\"java -cp . Server\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(), npmExecutable: npm)
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        var preferences = store.preferences(for: project.id)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        preferences.links = [ProjectLink(name: "Health", url: url)]
        try store.savePreferences(preferences)
        store.startSelectedProject()
        for _ in 0..<150 {
            if store.executionPhase == .ready { break }
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reached = store.executionPhase
        store.stopSelectedProject()
        for _ in 0..<100 {
            if store.executionPhase == .stopped { break }
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let stopped = store.executionPhase
        try await Task.sleep(for: .milliseconds(300))
        let endpointStillReady = (try? await LoopbackHTTPReadinessProbe().probe(url)) == true
        if endpointStillReady {
            // Test cleanup never stops by name or port alone; native identity and exact
            // project cwd are checked before signalling a leaked Java child.
            for process in (try? await LocalPortScanner().scan()) ?? [] where
                process.sockets.contains(where: { $0.port == port }) && process.workingDirectory == project.rootDirectory {
                let inspected = try NativeProcessInspector().inspect(pid: process.identity.pid)
                if inspected.identity == process.identity && inspected.identity.userID == getuid() {
                    _ = Darwin.kill(process.identity.pid, SIGTERM)
                }
            }
        }
        XCTAssertEqual(reached, .ready)
        XCTAssertEqual(stopped, .stopped)
        XCTAssertFalse(endpointStillReady, "Stopping the managed command must not leave its Java service running")
    }

    func test_liveNodeProject_whenCancelledDuringReadiness_shouldStopRecordedProcess() async throws {
        guard let npm = NPMExecutableResolver.resolve() else { throw XCTSkip("npm not installed") }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("setInterval(()=>{},1000)".utf8).write(to: root.appendingPathComponent("server.js"))
        try Data("{\"scripts\":{\"dev\":\"node server.js\"}}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   readinessProbe: NeverReadyProbe(), readinessTimeout: .seconds(2),
                                   npmExecutable: npm)
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        var preferences = store.preferences(for: project.id)
        preferences.links = [ProjectLink(name: "Health", url: URL(string: "http://127.0.0.1:65535/")!)]
        try store.savePreferences(preferences)
        store.startSelectedProject()
        for _ in 0..<100 {
            if store.executionPhase == .checkingReadiness { break }
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reached = store.executionPhase
        store.cancelSelectedProjectStart()
        for _ in 0..<100 {
            if store.executionPhase == .cancelled { break }
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(reached, .checkingReadiness)
        XCTAssertEqual(store.executionPhase, .cancelled)
        XCTAssertNil(store.managedProcess)
    }

    private func boundLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalReadFailure(kind: .unavailable) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { close(fd); throw LocalReadFailure(kind: .unavailable) }
        let retrieved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard retrieved == 0 else { close(fd); throw LocalReadFailure(kind: .unavailable) }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
}

private struct NeverReadyProbe: ProjectReadinessProbing {
    func probe(_ url: URL) async throws -> Bool { false }
}
