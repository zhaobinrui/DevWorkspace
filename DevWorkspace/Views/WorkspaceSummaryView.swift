import SwiftUI

struct WorkspaceSummaryView: View {
    @Environment(\.appLanguage) private var appLanguage

    let state: WorkspaceStore.State

    var body: some View {
        VStack(alignment: .leading, spacing: DevSpaceSpacing.medium) {
            statusHeader

            if let snapshot {
                snapshotMetadata(snapshot)

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

    private func snapshotMetadata(_ snapshot: WorkspaceSnapshot) -> some View {
        Label {
            HStack(spacing: DevSpaceSpacing.xSmall) {
                Text(snapshot.freshness.metadataLocalizationKey)
                Text(
                    snapshot.observedAt,
                    format: .dateTime.year().month().day().hour().minute()
                )
            }
        } icon: {
            Image(systemName: snapshot.freshness.metadataSystemImage)
        }
        .font(DevSpaceTypography.metadata)
        .foregroundStyle(
            snapshot.freshness == .stale ? Color.orange : Color.secondary
        )
        .accessibilityElement(children: .combine)
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
                    let presentation = ServiceHealthPresentation(
                        health: service.health,
                        language: appLanguage
                    )

                    HStack {
                        Image(systemName: presentation.systemImage)
                            .foregroundStyle(presentation.color)
                        Text(service.name)
                        Spacer()
                        Text(presentation.title)
                            .foregroundStyle(presentation.color)
                        if let port = service.port {
                            Text(String(port))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(DevSpaceTypography.body)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var snapshot: WorkspaceSnapshot? {
        // 刷新时继续渲染 previous，避免短暂空白；是否过期由 freshness 和状态提示明确表达。
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

private extension SnapshotFreshness {
    var metadataLocalizationKey: LocalizedStringKey {
        switch self {
        case .current:
            "workspace.snapshot.updated-at"
        case .stale:
            "workspace.snapshot.last-trusted-at"
        }
    }

    var metadataSystemImage: String {
        switch self {
        case .current:
            "clock"
        case .stale:
            "clock.badge.exclamationmark"
        }
    }
}
