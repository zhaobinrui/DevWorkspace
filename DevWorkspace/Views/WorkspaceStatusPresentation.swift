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
        case .degraded:
            self.init(
                title: language.localized("workspace.status.stale"),
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
