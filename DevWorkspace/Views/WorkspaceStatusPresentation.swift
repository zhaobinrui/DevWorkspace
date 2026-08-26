import SwiftUI

struct WorkspaceStatusPresentation {
    let title: String
    let semanticStatus: DevSpaceSemanticStatus

    var systemImage: String {
        semanticStatus.token.systemImage
    }

    var color: Color {
        semanticStatus.token.color
    }

    init(state: WorkspaceStore.State) {
        switch state {
        case .idle:
            self.init(title: "尚未加载", semanticStatus: .offline)
        case .refreshing:
            self.init(title: "正在刷新", semanticStatus: .inProgress)
        case let .ready(snapshot):
            self = Self(lifecycle: snapshot.lifecycle)
        case .degraded:
            self.init(title: "状态已过期", semanticStatus: .needsAttention)
        case .failed:
            self.init(title: "加载失败", semanticStatus: .failed)
        }
    }

    private init(lifecycle: WorkspaceLifecycle) {
        switch lifecycle {
        case .stopped:
            self.init(title: "已停止", semanticStatus: .inactive)
        case .starting:
            self.init(title: "正在启动", semanticStatus: .inProgress)
        case .ready:
            self.init(title: "已就绪", semanticStatus: .ready)
        case .degraded:
            self.init(title: "部分可用", semanticStatus: .needsAttention)
        case .failed:
            self.init(title: "运行失败", semanticStatus: .failed)
        }
    }

    private init(title: String, semanticStatus: DevSpaceSemanticStatus) {
        self.title = title
        self.semanticStatus = semanticStatus
    }
}
