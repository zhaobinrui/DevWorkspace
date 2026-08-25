import SwiftUI

struct WorkspaceStatusPresentation {
    let title: String
    let systemImage: String
    let color: Color

    init(state: WorkspaceStore.State) {
        switch state {
        case .idle:
            self.init(title: "尚未加载", systemImage: "circle", color: .secondary)
        case .refreshing:
            self.init(title: "正在刷新", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", color: .blue)
        case let .ready(snapshot):
            self = Self(lifecycle: snapshot.lifecycle)
        case .degraded:
            self.init(title: "状态已过期", systemImage: "exclamationmark.triangle.fill", color: .orange)
        case .failed:
            self.init(title: "加载失败", systemImage: "xmark.circle.fill", color: .red)
        }
    }

    private init(lifecycle: WorkspaceLifecycle) {
        switch lifecycle {
        case .stopped:
            self.init(title: "已停止", systemImage: "stop.circle", color: .secondary)
        case .starting:
            self.init(title: "正在启动", systemImage: "arrow.up.circle", color: .blue)
        case .ready:
            self.init(title: "已就绪", systemImage: "checkmark.circle.fill", color: .green)
        case .degraded:
            self.init(title: "部分可用", systemImage: "exclamationmark.triangle.fill", color: .orange)
        case .failed:
            self.init(title: "运行失败", systemImage: "xmark.circle.fill", color: .red)
        }
    }

    private init(title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }
}
