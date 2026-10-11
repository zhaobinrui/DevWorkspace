import Darwin
import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class WorkspaceControlTests: XCTestCase {
    func test_workspace_whenHomebrewDependencyIsStopped_shouldRefuseBeforeJavaLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("reviewed archive".utf8).write(to: root.appendingPathComponent("server.jar"))
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   homebrewReader: StoppedHomebrewReader())
        await store.discoverConfiguration()
        let archive = ProfileJavaArchive(relativePath: "server.jar", executablePath: "/usr/bin/java")
        let profile = ProjectProfile(homebrewServices: ["postgresql@17"],
            processReadinessURL: URL(string: "http://127.0.0.1:61234/health")!, javaArchive: archive)
        try store.saveProfileDraft(profile, for: project.id)
        await store.refreshJavaArchiveSource()
        try await store.trustProfile(for: project.id, reviewed: profile, packageDigest: nil,
                                     javaDigest: store.javaArchiveSource?.value?.digest)
        store.startSelectedWorkspace()
        for _ in 0..<100 {
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.workspacePhase, .failed(.homebrewNotReady))
        XCTAssertEqual(store.homebrewServices?.value?.first?.state, .stopped)
        XCTAssertNotNil(store.homebrewServices?.checkedAt)
        XCTAssertNil(store.managedProcess)
        XCTAssertNil(store.pendingProjectLaunch)
    }

    func test_javaArchive_whenSourceChanges_shouldRevokeTrustAndRefuseLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jar = root.appendingPathComponent("server.jar")
        try Data("first archive".utf8).write(to: jar)
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        await store.discoverConfiguration()
        let archive = ProfileJavaArchive(relativePath: "server.jar", executablePath: "/usr/bin/java")
        let profile = ProjectProfile(processReadinessURL: URL(string: "http://127.0.0.1:61234/health")!,
                                     javaArchive: archive)
        try store.saveProfileDraft(profile, for: project.id)
        await store.refreshJavaArchiveSource()
        let originalDigest = try XCTUnwrap(store.javaArchiveSource?.value?.digest)
        try await store.trustProfile(for: project.id, reviewed: profile, packageDigest: nil,
                                     javaDigest: originalDigest)
        XCTAssertEqual(store.profileTrustStatus(for: project), .trusted)

        try Data("changed archive".utf8).write(to: jar)
        await store.refreshJavaArchiveSource()
        XCTAssertEqual(store.profileTrustStatus(for: project), .sourceChanged)
        store.startSelectedProject()
        for _ in 0..<100 {
            if case .failed = store.executionPhase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.executionPhase, .failed(.sourceChanged))
        XCTAssertNil(store.managedProcess)
        XCTAssertNil(store.pendingProjectLaunch)
    }

    func test_javaArchive_whenPathEscapesOrIsSymlink_shouldRejectBeforeTrust() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ProfileJavaArchive(relativePath: "../other.jar", executablePath: "/usr/bin/java").isValid)
        let destination = root.appendingPathComponent("actual.jar")
        try Data("archive".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.jar"),
                                                   withDestinationURL: destination)
        do {
            _ = try await LocalJavaArchiveReader().read(root: root,
                archive: ProfileJavaArchive(relativePath: "linked.jar", executablePath: "/usr/bin/java"))
            XCTFail("A link may be changed after review and must not be trusted")
        } catch { }
    }

    func test_pendingLaunch_whenAppRestarts_shouldBlockDuplicateAndAllowGonePIDResolution() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let pending = PendingProjectLaunch(projectID: project.id, rootDirectory: root,
            commandLabel: "java -jar server.jar", pid: Int32.max, createdAt: .now)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id,
                                           pendingProjectLaunches: [pending]))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        XCTAssertEqual(store.executionPhase, .recoveryRequired)
        store.startSelectedProject()
        XCTAssertEqual(store.executionPhase, .recoveryRequired)
        store.removeSelectedProject()
        XCTAssertEqual(store.projectIssue?.kind, .activeManagedProcess)
        store.acknowledgePendingProjectLaunch()
        XCTAssertNil(store.pendingProjectLaunch)
        XCTAssertTrue(try repository.load().pendingProjectLaunches.isEmpty)
    }

    func test_workspace_whenTrustedNativeJava_shouldStartReadyOpenURLAndStop() async throws {
        let javaHome = try javaRuntimeHome()
        let javac = javaHome.appendingPathComponent("bin/javac").path
        let java = javaHome.appendingPathComponent("bin/java").path
        guard FileManager.default.isExecutableFile(atPath: javac),
              FileManager.default.isExecutableFile(atPath: java),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else {
            throw XCTSkip("A local JDK compiler, Java runtime and zip are required")
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try availablePort()
        let source = """
        import com.sun.net.httpserver.HttpServer;
        import java.net.InetSocketAddress;
        public class Server {
          public static void main(String[] args) throws Exception {
            HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", \(port)), 0);
            server.createContext("/health", e -> {
              byte[] bytes = "ready".getBytes("UTF-8");
              e.sendResponseHeaders(200, bytes.length);
              e.getResponseBody().write(bytes); e.close();
            });
            server.start(); Thread.sleep(30000); server.stop(0);
          }
        }
        """
        try Data(source.utf8).write(to: root.appendingPathComponent("Server.java"))
        try runTool(javac, ["Server.java"], directory: root)
        let manifestDirectory = root.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try Data("Manifest-Version: 1.0\nMain-Class: Server\n\n".utf8)
            .write(to: manifestDirectory.appendingPathComponent("MANIFEST.MF"))
        try runTool("/usr/bin/zip", ["-q", "-r", "server.jar", "META-INF", "Server.class"], directory: root)
        let project = try testProject(root)
        let repository = FileProjectCatalogRepository(fileURL: root.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let probe = ControllableJavaReadinessProbe()
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   readinessProbe: probe)
        await store.discoverConfiguration()
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let profile = ProjectProfile(processReadinessURL: url,
            javaArchive: ProfileJavaArchive(relativePath: "server.jar", executablePath: java))
        try store.saveProfileDraft(profile, for: project.id)
        await store.refreshJavaArchiveSource()
        try await store.trustProfile(for: project.id, reviewed: profile, packageDigest: nil,
                                     javaDigest: store.javaArchiveSource?.value?.digest)
        store.startSelectedWorkspace()
        for _ in 0..<200 {
            if store.workspacePhase == .ready { break }
            if case .failed = store.workspacePhase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let reached = store.workspacePhase
        let readyURL = store.readyPrimaryURL
        await probe.setUnavailable(true)
        await store.refresh()
        XCTAssertEqual(store.operationalLifecycle, .degraded,
                       "A failed fresh health probe must revoke historical Ready")
        XCTAssertNil(store.readyPrimaryURL)
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
        XCTAssertTrue(try repository.load().managedProcesses.isEmpty)
    }

    private func runTool(_ path: String, _ arguments: [String], directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail("\(path) \(arguments.joined(separator: " ")): \(detail)")
            throw LocalReadFailure(kind: .unavailable)
        }
    }

    private func javaRuntimeHome() throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/") else { throw XCTSkip("No usable local Java runtime") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func availablePort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalReadFailure(kind: .unavailable) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard bound == 0 else { throw LocalReadFailure(kind: .unavailable) }
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard read == 0 else { throw LocalReadFailure(kind: .unavailable) }
        return UInt16(bigEndian: address.sin_port)
    }
}

private actor ControllableJavaReadinessProbe: ProjectReadinessProbing {
    private var unavailable = false
    private let live = LoopbackHTTPReadinessProbe()

    func setUnavailable(_ value: Bool) { unavailable = value }

    func probe(_ url: URL) async throws -> Bool {
        if unavailable { return false }
        return try await live.probe(url)
    }
}

private struct StoppedHomebrewReader: HomebrewServiceStatusReading {
    func read(names: [String]) async throws -> [HomebrewServiceStatus] {
        names.map { HomebrewServiceStatus(name: $0, state: .stopped, pid: nil) }
    }
}
