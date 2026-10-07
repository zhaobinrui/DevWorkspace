import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class SharedUserProcessTests: XCTestCase {
    func test_projectSwitch_shouldReuseProcessesAndRefreshGitIndependently() async throws {
        let a = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let b = try testProject(URL(fileURLWithPath: "/private/tmp/b"))
        let scanner = CountingProcessScanner(results: [.success([testProcess(directory: a.rootDirectory.path), testProcess(pid: 66, directory: b.rootDirectory.path)]), .success([])])
        let provider = ObservedWorkspaceSnapshotProvider(gitReader: EmptyGitReader(), portScanner: scanner,
                                                         composeReader: EmptyComposeReader())
        let store = WorkspaceStore(project: a, provider: provider, rootResolver: FixtureProjectResolver(project: b))
        await store.refresh(forceProcessRefresh: false)
        let original = store.userProcesses
        await store.addProject(at: b.rootDirectory)
        XCTAssertEqual(store.userProcesses, original)
        XCTAssertEqual(store.projectProcesses.map(\.identity.pid), [66])
        await store.refresh(forceProcessRefresh: false)
        let scansAfterSwitch = await scanner.calls
        XCTAssertEqual(scansAfterSwitch, 1)
        XCTAssertEqual(store.userProcesses, original)
        await store.refreshUserProcesses()
        let scansAfterForce = await scanner.calls
        XCTAssertEqual(scansAfterForce, 2)
        XCTAssertEqual(store.projectProcesses, [])
        XCTAssertEqual(store.currentSnapshot?.readings?.ports.value, [])
    }

    func test_processes_withoutProject_shouldStillLoadAndReportEmpty() async {
        let scanner = CountingProcessScanner(results: [.success([])])
        let store = WorkspaceStore(provider: ObservedWorkspaceSnapshotProvider(gitReader: EmptyGitReader(), portScanner: scanner,
                                                                               composeReader: EmptyComposeReader()))
        await store.refreshUserProcesses()
        XCTAssertNil(store.project)
        XCTAssertEqual(store.userProcesses?.value, [])
        XCTAssertNil(store.userProcesses?.failure)
    }

    func test_failure_shouldKeepSharedValueAndDateAcrossProjectSelectionThenRecover() async throws {
        let scanner = CountingProcessScanner(results: [.success([testProcess()]), .failure(.init(kind: .permissionDenied)), .success([])])
        let reader = SharedUserProcessReader(scanner: scanner)
        let first = try await reader.read()
        let failed = try await reader.read(force: true)
        XCTAssertEqual(failed.value, first.value)
        XCTAssertEqual(failed.checkedAt, first.checkedAt)
        XCTAssertEqual(failed.failure?.kind, .permissionDenied)
        let cachedFailure = try await reader.read()
        XCTAssertEqual(cachedFailure, failed)
        let recovered = try await reader.read(force: true)
        XCTAssertEqual(recovered.value, [])
        XCTAssertNil(recovered.failure)
        let scans = await scanner.calls
        XCTAssertEqual(scans, 3)
    }

    func test_processFailure_shouldUpdateProjectStatusWithoutRereadingGit() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/a"))
        let scanner = CountingProcessScanner(results: [.success([testProcess()]), .failure(.init(kind: .timedOut)), .success([])])
        let store = WorkspaceStore(project: project, provider: ObservedWorkspaceSnapshotProvider(gitReader: EmptyGitReader(), portScanner: scanner,
                                                                                                  composeReader: EmptyComposeReader()))
        await store.refresh()
        let originalGit = store.currentSnapshot?.readings?.git
        await store.refreshUserProcesses()
        guard case .degraded = store.state else { return XCTFail("Expected shared failure on project summary") }
        XCTAssertEqual(store.currentSnapshot?.readings?.git, originalGit)
        XCTAssertEqual(store.currentSnapshot?.readings?.ports.failure?.kind, .timedOut)
        XCTAssertEqual(store.userProcesses?.value?.count, 1)
        await store.refreshUserProcesses()
        guard case .ready = store.state else { return XCTFail("Expected shared recovery") }
        XCTAssertEqual(store.currentSnapshot?.readings?.git, originalGit)
    }

    func test_missingRepository_shouldNotPreventUserProcessObservation() async throws {
        let project = try testProject(URL(fileURLWithPath: "/private/tmp/nonexistent-" + UUID().uuidString))
        let scanner = CountingProcessScanner(results: [.success([])])
        let provider = ObservedWorkspaceSnapshotProvider(portScanner: scanner, composeReader: EmptyComposeReader())
        let snapshot = try await provider.snapshot(for: project)
        XCTAssertNotNil(snapshot.readings?.git.failure)
        XCTAssertNil(snapshot.readings?.ports.failure)
        XCTAssertEqual(snapshot.readings?.ports.value, [])
    }

    func test_expiredCache_shouldReadAgain() async throws {
        let scanner = CountingProcessScanner(results: [.success([testProcess()]), .success([])])
        let reader = SharedUserProcessReader(scanner: scanner, maximumAge: 0)
        _ = try await reader.read()
        let next = try await reader.read()
        XCTAssertEqual(next.value, [])
        let scans = await scanner.calls
        XCTAssertEqual(scans, 2)
    }

    func test_concurrentRefresh_whenOneConsumerCancels_shouldKeepOtherConsumerAndUseOneScan() async throws {
        let scanner = GatedProcessScanner()
        let reader = SharedUserProcessReader(scanner: scanner)
        let first = Task { try await reader.read(force: true) }
        let second = Task { try await reader.read(force: true) }
        while await reader.activeReadCount != 2 { await Task.yield() }
        first.cancel()
        while await reader.activeReadCount != 1 { await Task.yield() }
        while await scanner.calls == 0 { await Task.yield() }
        await scanner.finish()
        let value = try await second.value
        XCTAssertEqual(value.value, [])
        do { _ = try await first.value; XCTFail("Cancelled consumer must not publish") }
        catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let calls = await scanner.calls
        XCTAssertEqual(calls, 1)
    }

    func test_cancelLastConsumer_shouldCancelChildAndAllowRetry() async throws {
        let scanner = GatedProcessScanner()
        let reader = SharedUserProcessReader(scanner: scanner)
        let cancelled = Task { try await reader.read() }
        while await scanner.calls == 0 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error") }
        let retry = Task { try await reader.read() }
        while await scanner.calls < 2 { await Task.yield() }
        await scanner.finish()
        let result = try await retry.value
        XCTAssertEqual(result.value, [])
    }
}

private struct EmptyGitReader: GitStatusReading {
    func status(for project: ProjectReference) async throws -> GitSummary? { nil }
}

private struct EmptyComposeReader: DockerComposeStatusReading {
    func read(root: URL) async throws -> ComposeProjectStatus? { nil }
}

private actor CountingProcessScanner: LocalPortScanning {
    var calls = 0
    var results: [Result<[ListeningProcess], LocalReadFailure>]
    init(results: [Result<[ListeningProcess], LocalReadFailure>]) { self.results = results }
    func scan() async throws -> [ListeningProcess] { calls += 1; return try results.removeFirst().get() }
}

private actor GatedProcessScanner: LocalPortScanning {
    var calls = 0
    private var continuation: CheckedContinuation<[ListeningProcess], any Error>?
    func scan() async throws -> [ListeningProcess] {
        calls += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { Task { await self.cancel() } }
    }
    func finish() { continuation?.resume(returning: []); continuation = nil }
    private func cancel() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}
