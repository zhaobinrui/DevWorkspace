import Foundation
import Observation

enum WorkspaceStateMessage: Equatable, Sendable {
    case restoredSnapshot
    case refreshCancelled
    case provider(String)

    func localized(in language: AppLanguage) -> String {
        switch self {
        case .restoredSnapshot:
            language.localized("workspace.message.restored-snapshot")
        case .refreshCancelled:
            language.localized("workspace.message.refresh-cancelled")
        case let .provider(message):
            message
        }
    }
}

@MainActor
@Observable
final class WorkspaceStore {
    enum State: Equatable, Sendable {
        case idle
        case refreshing(previous: WorkspaceSnapshot?)
        case ready(WorkspaceSnapshot)
        case degraded(snapshot: WorkspaceSnapshot, message: WorkspaceStateMessage)
        case failed(message: WorkspaceStateMessage)
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
            // 磁盘恢复的数据只能作为上一次可信状态展示，未经本次进程重新采集不能标记为实时。
            state = .degraded(
                snapshot: restoredSnapshot.markedStale(),
                message: .restoredSnapshot
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

        // 刷新期间保留旧快照，避免菜单栏短暂退回空状态；新结果成功后再原子替换。
        let previous = currentSnapshot
        state = .refreshing(previous: previous)

        do {
            let snapshot = try await provider.snapshot(for: project)
            try Task.checkCancellation()
            state = .ready(snapshot)
        } catch is CancellationError {
            // 取消是调用方主动结束工作，不等同于数据源故障，因此恢复原可信状态且不制造错误。
            if let previous {
                state = previous.freshness == .stale
                    ? .degraded(snapshot: previous, message: .refreshCancelled)
                    : .ready(previous)
            } else {
                state = .idle
            }
        } catch {
            // 采集失败时继续展示最后一次可信数据，但明确降级为 stale，避免旧数据伪装成实时状态。
            if let previous {
                state = .degraded(
                    snapshot: previous.markedStale(),
                    message: .provider(error.localizedDescription)
                )
            } else {
                state = .failed(message: .provider(error.localizedDescription))
            }
        }
    }
}
