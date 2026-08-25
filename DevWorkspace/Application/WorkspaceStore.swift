import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceStore {
    enum State: Equatable, Sendable {
        case idle
        case refreshing(previous: WorkspaceSnapshot?)
        case ready(WorkspaceSnapshot)
        case degraded(snapshot: WorkspaceSnapshot, message: String)
        case failed(message: String)
    }

    let project: ProjectReference
    private(set) var state: State

    private let provider: any WorkspaceSnapshotProviding

    init(
        project: ProjectReference,
        provider: any WorkspaceSnapshotProviding,
        restoredSnapshot: WorkspaceSnapshot? = nil
    ) {
        self.project = project
        self.provider = provider

        if let restoredSnapshot {
            state = .degraded(
                snapshot: restoredSnapshot.markedStale(),
                message: "显示上次可信状态，等待刷新"
            )
        } else {
            state = .idle
        }
    }

    var currentSnapshot: WorkspaceSnapshot? {
        switch state {
        case .idle, .failed:
            nil
        case let .refreshing(previous):
            previous
        case let .ready(snapshot), let .degraded(snapshot, _):
            snapshot
        }
    }

    var isRefreshing: Bool {
        if case .refreshing = state {
            true
        } else {
            false
        }
    }

    var shouldLoad: Bool {
        if case .idle = state {
            true
        } else {
            false
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }

        let previous = currentSnapshot
        state = .refreshing(previous: previous)

        do {
            let snapshot = try await provider.snapshot(for: project)
            try Task.checkCancellation()
            state = .ready(snapshot)
        } catch is CancellationError {
            if let previous {
                state = previous.freshness == .stale
                    ? .degraded(snapshot: previous, message: "刷新已取消，显示上次可信状态")
                    : .ready(previous)
            } else {
                state = .idle
            }
        } catch {
            if let previous {
                state = .degraded(
                    snapshot: previous.markedStale(),
                    message: error.localizedDescription
                )
            } else {
                state = .failed(message: error.localizedDescription)
            }
        }
    }
}
