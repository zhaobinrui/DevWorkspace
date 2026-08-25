import SwiftUI

struct WorkspaceSummaryView: View {
    let state: WorkspaceStore.State

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            if let snapshot {
                if snapshot.origin == .preview {
                    Label("框架预览数据", systemImage: "hammer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                gitSection(snapshot.git)
                servicesSection(snapshot.services)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusHeader: some View {
        let presentation = WorkspaceStatusPresentation(state: state)

        return HStack(spacing: 8) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.color)
            Text(presentation.title)
                .font(.headline)

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
            VStack(alignment: .leading, spacing: 4) {
                Text("Git")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(git.branch) · ↑\(git.commitsAhead) ↓\(git.commitsBehind) · \(git.changedFileCount) files changed")
                    .font(.callout.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private func servicesSection(_ services: [ServiceSummary]) -> some View {
        if !services.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Services")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(services) { service in
                    HStack {
                        Image(systemName: service.health.systemImage)
                            .foregroundStyle(service.health.color)
                        Text(service.name)
                        Spacer()
                        if let port = service.port {
                            Text(String(port))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.callout)
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

    private var message: String? {
        switch state {
        case let .degraded(_, message), let .failed(message):
            message
        case .idle, .refreshing, .ready:
            nil
        }
    }
}

private extension ServiceHealth {
    var systemImage: String {
        switch self {
        case .stopped:
            "circle"
        case .starting:
            "arrow.up.circle"
        case .healthy:
            "checkmark.circle.fill"
        case .unhealthy:
            "xmark.circle.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .stopped, .unknown:
            .secondary
        case .starting:
            .blue
        case .healthy:
            .green
        case .unhealthy:
            .red
        }
    }
}
