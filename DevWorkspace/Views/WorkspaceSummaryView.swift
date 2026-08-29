import SwiftUI

struct WorkspaceSummaryView: View {
    @Environment(\.appLanguage) private var appLanguage

    let state: WorkspaceStore.State

    var body: some View {
        VStack(alignment: .leading, spacing: DevSpaceSpacing.medium) {
            statusHeader

            if let snapshot {
                if snapshot.origin == .preview {
                    Label("workspace.preview-data", systemImage: "hammer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                gitSection(snapshot.git)
                servicesSection(snapshot.services)
            }

            if let message {
                Text(message.localized(in: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusHeader: some View {
        let presentation = WorkspaceStatusPresentation(
            state: state,
            language: appLanguage
        )

        return HStack(spacing: DevSpaceSpacing.small) {
            DevSpaceStatusBadge(
                status: presentation.semanticStatus,
                title: presentation.title
            )

            Spacer()

            if case .refreshing = state {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func gitSection(_ git: GitSummary?) -> some View {
        if let git {
            VStack(alignment: .leading, spacing: DevSpaceSpacing.xSmall) {
                Text("Git")
                    .font(DevSpaceTypography.sectionLabel)
                    .foregroundStyle(.secondary)
                Text(gitSummary(git))
                    .font(DevSpaceTypography.body.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func servicesSection(_ services: [ServiceSummary]) -> some View {
        if !services.isEmpty {
            VStack(alignment: .leading, spacing: DevSpaceSpacing.small) {
                Text("workspace.section.services")
                    .font(DevSpaceTypography.sectionLabel)
                    .foregroundStyle(.secondary)

                ForEach(services) { service in
                    let token = service.health.semanticStatus.token

                    HStack {
                        Image(systemName: token.systemImage)
                            .foregroundStyle(token.color)
                        Text(service.name)
                        Spacer()
                        if let port = service.port {
                            Text(String(port))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(DevSpaceTypography.body)
                }
            }
        }
    }

    private var snapshot: WorkspaceSnapshot? {
        switch state {
        case let .refreshing(previous):
            previous
        case let .ready(snapshot), let .degraded(snapshot, _):
            snapshot
        case .idle, .failed:
            nil
        }
    }

    private var message: WorkspaceStateMessage? {
        switch state {
        case let .degraded(_, message), let .failed(message):
            message
        case .idle, .refreshing, .ready:
            nil
        }
    }

    private func gitSummary(_ git: GitSummary) -> String {
        String(
            format: appLanguage.localized("workspace.git.summary-format"),
            locale: appLanguage.locale,
            git.branch,
            Int64(git.commitsAhead),
            Int64(git.commitsBehind),
            Int64(git.changedFileCount)
        )
    }
}

private extension ServiceHealth {
    var semanticStatus: DevSpaceSemanticStatus {
        switch self {
        case .stopped:
            .inactive
        case .starting:
            .inProgress
        case .healthy:
            .ready
        case .unhealthy:
            .failed
        case .unknown:
            .offline
        }
    }
}
