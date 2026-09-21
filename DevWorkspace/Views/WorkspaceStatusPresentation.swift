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

    init(state: WorkspaceStore.State, language: AppLanguage) {
        switch state {
        case .idle:
            self.init(
                title: language.localized("workspace.status.idle"),
                semanticStatus: .offline
            )
        case .refreshing:
            self.init(
                title: language.localized("workspace.status.refreshing"),
                semanticStatus: .inProgress
            )
        case let .ready(snapshot):
            self = Self(lifecycle: snapshot.lifecycle, language: language)
        case let .degraded(snapshot, _):
            self.init(
                title: language.localized(snapshot.readings == nil ? "workspace.status.stale" : "workspace.status.read-errors"),
                semanticStatus: .needsAttention
            )
        case .failed:
            self.init(
                title: language.localized("workspace.status.load-failed"),
                semanticStatus: .failed
            )
        }
    }

    private init(lifecycle: WorkspaceLifecycle, language: AppLanguage) {
        switch lifecycle {
        case .observed:
            self.init(title: language.localized("workspace.status.observed"), semanticStatus: .ready)
        case .stopped:
            self.init(
                title: language.localized("workspace.status.stopped"),
                semanticStatus: .inactive
            )
        case .starting:
            self.init(
                title: language.localized("workspace.status.starting"),
                semanticStatus: .inProgress
            )
        case .ready:
            self.init(
                title: language.localized("workspace.status.ready"),
                semanticStatus: .ready
            )
        case .degraded:
            self.init(
                title: language.localized("workspace.status.degraded"),
                semanticStatus: .needsAttention
            )
        case .failed:
            self.init(
                title: language.localized("workspace.status.failed"),
                semanticStatus: .failed
            )
        }
    }

    private init(title: String, semanticStatus: DevSpaceSemanticStatus) {
        self.title = title
        self.semanticStatus = semanticStatus
    }
}

enum MenuBarVisualPriority: Equatable, Sendable {
    case quiet
    case active
    case elevated
}

struct MenuBarStatusPresentation {
    let title: String
    let semanticStatus: DevSpaceSemanticStatus
    let visualPriority: MenuBarVisualPriority

    var visibleTitle: String {
        visualPriority == .quiet ? "" : title
    }

    var showsTitle: Bool {
        !visibleTitle.isEmpty
    }

    init(state: WorkspaceStore.State, language: AppLanguage) {
        let workspace = WorkspaceStatusPresentation(
            state: state,
            language: language
        )

        title = workspace.title
        semanticStatus = workspace.semanticStatus
        // 菜单栏模板图标由系统统一着色；通过是否展开文字调整视觉权重，
        // 才能在不依赖颜色的前提下让短暂状态和异常状态被看见。
        visualPriority = switch workspace.semanticStatus {
        case .inactive, .ready:
            .quiet
        case .inProgress:
            .active
        case .needsAttention, .failed, .offline:
            .elevated
        }
    }
}

struct ServiceHealthPresentation {
    let title: String
    let semanticStatus: DevSpaceSemanticStatus

    var systemImage: String {
        semanticStatus.token.systemImage
    }

    var color: Color {
        semanticStatus.token.color
    }

    init(health: ServiceHealth, language: AppLanguage) {
        switch health {
        case .stopped:
            self.init(
                title: language.localized("service.status.stopped"),
                semanticStatus: .inactive
            )
        case .starting:
            self.init(
                title: language.localized("service.status.starting"),
                semanticStatus: .inProgress
            )
        case .healthy:
            self.init(
                title: language.localized("service.status.healthy"),
                semanticStatus: .ready
            )
        case .unhealthy:
            self.init(
                title: language.localized("service.status.unhealthy"),
                semanticStatus: .failed
            )
        case .unknown:
            self.init(
                title: language.localized("service.status.unknown"),
                semanticStatus: .offline
            )
        }
    }

    private init(title: String, semanticStatus: DevSpaceSemanticStatus) {
        self.title = title
        self.semanticStatus = semanticStatus
    }
}
