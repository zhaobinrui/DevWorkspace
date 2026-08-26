import XCTest
@testable import DevWorkspace

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func test_refresh_whenProviderSucceeds_shouldPublishCurrentSnapshot() async {
        let snapshot = makeSnapshot()
        let store = makeStore(provider: ScriptedSnapshotProvider([.snapshot(snapshot)]))

        await store.refresh()

        XCTAssertEqual(store.state, .ready(snapshot))
    }

    func test_refresh_whenInitialLoadFails_shouldPublishFailure() async {
        let store = makeStore(provider: ScriptedSnapshotProvider([.failure("offline")]))

        await store.refresh()

        XCTAssertEqual(store.state, .failed(message: "offline"))
    }

    func test_refresh_whenRefreshFails_shouldPreserveLastTrustedSnapshotAsStale() async {
        let snapshot = makeSnapshot()
        let provider = ScriptedSnapshotProvider([.snapshot(snapshot), .failure("offline")])
        let store = makeStore(provider: provider)
        await store.refresh()

        await store.refresh()

        XCTAssertEqual(
            store.state,
            .degraded(snapshot: snapshot.markedStale(), message: "offline")
        )
    }

    func test_refresh_whenCancelled_shouldRestorePreviousState() async {
        let snapshot = makeSnapshot()
        let provider = ScriptedSnapshotProvider([.snapshot(snapshot), .cancellation])
        let store = makeStore(provider: provider)
        await store.refresh()

        await store.refresh()

        XCTAssertEqual(store.state, .ready(snapshot))
    }

    func test_refresh_whenRetriedAfterFailure_shouldRecover() async {
        let snapshot = makeSnapshot()
        let provider = ScriptedSnapshotProvider([.failure("offline"), .snapshot(snapshot)])
        let store = makeStore(provider: provider)
        await store.refresh()

        await store.refresh()

        XCTAssertEqual(store.state, .ready(snapshot))
    }

    func test_init_whenSnapshotIsRestored_shouldMarkItStale() {
        let snapshot = makeSnapshot()

        let store = makeStore(
            provider: ScriptedSnapshotProvider([]),
            restoredSnapshot: snapshot
        )

        XCTAssertEqual(
            store.state,
            .degraded(
                snapshot: snapshot.markedStale(),
                message: "显示上次可信状态，等待刷新"
            )
        )
    }

    private func makeStore(
        provider: any WorkspaceSnapshotProviding,
        restoredSnapshot: WorkspaceSnapshot? = nil
    ) -> WorkspaceStore {
        WorkspaceStore(
            project: makeProject(),
            provider: provider,
            restoredSnapshot: restoredSnapshot
        )
    }

    private func makeProject() -> ProjectReference {
        let identity = try! LocalProjectIdentityResolver().resolve(
            rootDirectory: URL(fileURLWithPath: "/private/tmp/example", isDirectory: true),
            declaredMetadataID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )

        return ProjectReference(
            identity: identity,
            name: "Example"
        )
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            project: makeProject(),
            lifecycle: .ready,
            git: nil,
            services: [],
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            freshness: .current,
            origin: .local
        )
    }
}

private actor ScriptedSnapshotProvider: WorkspaceSnapshotProviding {
    enum Outcome: Sendable {
        case snapshot(WorkspaceSnapshot)
        case failure(String)
        case cancellation
    }

    private var outcomes: [Outcome]

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        guard !outcomes.isEmpty else {
            throw TestProviderError(message: "No scripted outcome")
        }

        return switch outcomes.removeFirst() {
        case let .snapshot(snapshot):
            snapshot
        case let .failure(message):
            throw TestProviderError(message: message)
        case .cancellation:
            throw CancellationError()
        }
    }
}

private struct TestProviderError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
