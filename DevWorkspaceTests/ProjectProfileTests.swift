import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class ProjectProfileTests: XCTestCase {
    func test_profile_whenReviewed_shouldPersistTrustWithoutSavingScriptBody() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePackage(root, script: "echo never-store-this-secret")
        let project = try testProject(root)
        let catalogURL = root.appendingPathComponent("catalog.json")
        let repository = FileProjectCatalogRepository(fileURL: catalogURL)
        try repository.save(ProjectCatalog(projects: [project], selectedID: project.id))
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        await store.discoverConfiguration()
        let discovery = try XCTUnwrap(store.discovery?.value)
        XCTAssertEqual(discovery.packageScripts.first?.body, "echo never-store-this-secret")
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")],
                                   homebrewServices: ["redis"])
        try store.saveProfileDraft(draft, for: project.id)
        XCTAssertEqual(store.profileTrustStatus(for: project), .draft)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: discovery.packageDigest)
        XCTAssertEqual(store.profileTrustStatus(for: project), .trusted)
        let saved = try String(contentsOf: catalogURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("never-store-this-secret"))
        let restored = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository)
        XCTAssertNotNil(restored.preferences(for: project.id).profile?.trust)
        XCTAssertEqual(restored.profileTrustStatus(for: project), .needsScan)
        await restored.discoverConfiguration()
        XCTAssertEqual(restored.profileTrustStatus(for: project), .trusted)
    }

    func test_profile_whenSourceOrDraftChanges_shouldRevokeTrust() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePackage(root, script: "node server.js")
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        XCTAssertEqual(store.profileTrustStatus(for: project), .trusted)
        try writePackage(root, script: "node changed.js")
        await store.discoverConfiguration()
        XCTAssertEqual(store.profileTrustStatus(for: project), .sourceChanged)
        var changed = draft
        changed.homebrewServices = ["postgresql@17"]
        try store.saveProfileDraft(changed, for: project.id)
        XCTAssertEqual(store.profileTrustStatus(for: project), .draft)
        XCTAssertNil(store.preferences(for: project.id).profile?.trust)
    }

    func test_profile_whenPackageChangesBetweenPreviewAndConfirmation_shouldRejectTrust() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePackage(root, script: "node server.js")
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        await store.discoverConfiguration()
        let reviewedDigest = store.discovery?.value?.packageDigest
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try writePackage(root, script: "node changed.js")
        do {
            try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: reviewedDigest)
            XCTFail("A changed script must require a new preview")
        } catch ProfileFailure.reviewChanged { }
        XCTAssertNil(store.preferences(for: project.id).profile?.trust)
    }

    func test_profile_whenInvalidDependencyOrMissingScript_shouldReject() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePackage(root, script: "node server.js")
        let project = try testProject(root)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        XCTAssertFalse(ProjectProfile.validHomebrewName("redis; rm -rf /"))
        XCTAssertThrowsError(try store.saveProfileDraft(ProjectProfile(homebrewServices: ["redis; rm -rf /"]), for: project.id))
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "missing")])
        try store.saveProfileDraft(draft, for: project.id)
        do {
            try await store.trustProfile(for: project.id, reviewed: draft,
                                         packageDigest: store.discovery?.value?.packageDigest)
            XCTFail("A missing script must not become trusted")
        } catch ProfileFailure.missingScript { }
    }

    func test_profile_whenOldCatalogOrMissingPackage_shouldStaySafe() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try testProject(root)
        let old = ProjectPreferences(projectID: project.id, editor: nil, links: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "profile")
        let decoded = try JSONDecoder().decode(ProjectPreferences.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.profile)
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider())
        await store.discoverConfiguration()
        let draft = ProjectProfile(homebrewServices: ["redis"])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft, packageDigest: nil)
        XCTAssertEqual(store.profileTrustStatus(for: project), .trusted)
        XCTAssertFalse(ProjectProfile.validScriptName("--help"))
        XCTAssertFalse(ProjectProfile.validHomebrewName("-redis"))
    }

    func test_profile_whenConfigurationReadFails_shouldNotClaimTrustFromCachedDigest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePackage(root, script: "node server.js")
        let project = try testProject(root)
        let reader = ProfileConfigurationFixture()
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(), configurationReader: reader)
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: project.id)
        try await store.trustProfile(for: project.id, reviewed: draft,
                                     packageDigest: store.discovery?.value?.packageDigest)
        XCTAssertEqual(store.profileTrustStatus(for: project), .trusted)
        await reader.failNextRead()
        await store.discoverConfiguration()
        XCTAssertEqual(store.profileTrustStatus(for: project), .needsScan)
        XCTAssertNotNil(store.discovery?.value)
    }

    func test_profile_whenProjectChangesDuringTrustRead_shouldRejectOldSelection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let aRoot = directory.appendingPathComponent("a", isDirectory: true)
        let bRoot = directory.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: aRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bRoot, withIntermediateDirectories: true)
        try writePackage(aRoot, script: "node server.js")
        let a = try testProject(aRoot)
        let b = try testProject(bRoot)
        let repository = FileProjectCatalogRepository(fileURL: directory.appendingPathComponent("catalog.json"))
        try repository.save(ProjectCatalog(projects: [a, b], selectedID: a.id))
        let reader = PausedTrustReader()
        let store = WorkspaceStore(provider: PreviewWorkspaceSnapshotProvider(), catalogRepository: repository,
                                   configurationReader: reader)
        await store.discoverConfiguration()
        let draft = ProjectProfile(commands: [ProfileScriptCommand(role: .start, scriptName: "dev")])
        try store.saveProfileDraft(draft, for: a.id)
        let digest = store.discovery?.value?.packageDigest
        let attempt = Task { try await store.trustProfile(for: a.id, reviewed: draft, packageDigest: digest) }
        while !(await reader.isPaused) { await Task.yield() }
        store.selectProject(b.id)
        await reader.resume()
        do {
            try await attempt.value
            XCTFail("Trust must not be saved for a project that is no longer selected")
        } catch ProfileFailure.projectChanged { }
        XCTAssertNil(store.preferences(for: a.id).profile?.trust)
        XCTAssertNil(store.preferences(for: b.id).profile)
    }

    private func writePackage(_ root: URL, script: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["scripts": ["dev": script]])
        try data.write(to: root.appendingPathComponent("package.json"))
    }
}

private actor ProfileConfigurationFixture: ProjectConfigurationReading {
    private var shouldFail = false
    func failNextRead() { shouldFail = true }
    func read(root: URL) async throws -> ProjectDiscovery {
        if shouldFail {
            shouldFail = false
            throw LocalReadFailure(kind: .permissionDenied)
        }
        return try LocalProjectConfigurationReader.scan(root: root)
    }
}

private actor PausedTrustReader: ProjectConfigurationReading {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var isPaused: Bool { continuation != nil }
    func read(root: URL) async throws -> ProjectDiscovery {
        calls += 1
        if calls == 2 { await withCheckedContinuation { continuation = $0 } }
        return try LocalProjectConfigurationReader.scan(root: root)
    }
    func resume() { continuation?.resume(); continuation = nil }
}
