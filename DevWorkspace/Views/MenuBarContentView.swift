import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var store: WorkspaceStore
    @Bindable var appearanceSettings: AppearanceSettings
    let openWorkspace: @MainActor () -> Void
    let openProjectFolder: @MainActor (URL) -> Void
    let openExternalURL: @MainActor (URL) -> Void
    let copyText: @MainActor (String) -> Void
    let refresh: @MainActor () async -> Void

    @State private var isAddressExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            productHeader
            Divider()
            projectHeader
            lifecycleStrip

            if let snapshot {
                readyMessage(snapshot)
                workspaceSteps(snapshot)
            }

            if let stateMessage {
                Text(stateMessage.localized(in: appLanguage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DevSpaceSpacing.small)
            }

            Divider()
                .padding(.top, DevSpaceSpacing.medium)
            footerActions
        }
        .padding(DevSpaceSpacing.medium)
        .frame(width: DevSpaceLayout.menuBarWidth)
        .menuBarSurface(
            preferences: appearanceSettings.preferences,
            cornerRadius: DevSpaceCornerRadius.panel
        )
        .preferredColorScheme(
            appearanceSettings.colorMode.preferredColorScheme
        )
        .task {
            if store.shouldLoad {
                await refresh()
            }
        }
    }

    private var productHeader: some View {
        HStack(spacing: DevSpaceSpacing.small) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            Text(DevSpaceProduct.workspace.displayName)
                .font(.headline)

            Spacer()

            Button(action: openWorkspace) {
                Label("workspace.action.open", systemImage: "folder")
            }
            .buttonStyle(
                DevSpaceActionButtonStyle(
                    role: .secondary,
                    fillsWidth: false
                )
            )
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityIdentifier("menuBar.openWorkspace")
        }
        .padding(.bottom, DevSpaceSpacing.medium)
    }

    private var projectHeader: some View {
        HStack(alignment: .top, spacing: DevSpaceSpacing.medium) {
            Image(systemName: "folder.fill.badge.gearshape")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: DevSpaceCornerRadius.compact)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DevSpaceSpacing.xSmall) {
                HStack(spacing: DevSpaceSpacing.small) {
                    Text(store.project.name)
                        .font(.title3.bold())
                        .lineLimit(1)

                    statusLabel
                }

                if let snapshot, let git = snapshot.git {
                    Label(gitSummary(git), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(store.project.rootDirectory.path())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(
                DevSpaceActionButtonStyle(
                    role: .quiet,
                    fillsWidth: false
                )
            )
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help(Text("workspace.action.refresh"))
            .accessibilityLabel(Text("workspace.action.refresh"))
            .accessibilityIdentifier("menuBar.refresh")
        }
        .padding(.vertical, DevSpaceSpacing.medium)
    }

    private var statusLabel: some View {
        let presentation = WorkspaceStatusPresentation(
            state: store.state,
            language: appLanguage
        )

        return Label(presentation.title, systemImage: presentation.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(presentation.color)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }

    private var lifecycleStrip: some View {
        HStack(spacing: DevSpaceSpacing.xSmall) {
            LifecycleStageView(
                title: appLanguage.localized("workspace.status.stopped"),
                systemImage: "stop.fill",
                color: .secondary,
                isCurrent: currentLifecycle == .stopped
            )

            lifecycleConnector

            LifecycleStageView(
                title: appLanguage.localized("workspace.status.starting"),
                systemImage: "play.fill",
                color: .blue,
                isCurrent: currentLifecycle == .starting
            )

            lifecycleConnector

            LifecycleStageView(
                title: appLanguage.localized("workspace.status.ready"),
                systemImage: "checkmark",
                color: .green,
                isCurrent: currentLifecycle == .ready
            )
        }
        .padding(.vertical, DevSpaceSpacing.small)
        .accessibilityElement(children: .contain)
    }

    private var lifecycleConnector: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(height: 1)
    }

    private func readyMessage(_ snapshot: WorkspaceSnapshot) -> some View {
        let presentation = WorkspaceStatusPresentation(
            state: store.state,
            language: appLanguage
        )
        let healthyCount = snapshot.services.filter { $0.health == .healthy }.count
        let message = String(
            format: appLanguage.localized("workspace.summary.health-format"),
            locale: appLanguage.locale,
            store.project.name,
            Int64(healthyCount),
            Int64(snapshot.services.count)
        )

        return Label(message, systemImage: presentation.systemImage)
            .font(.callout)
            .foregroundStyle(presentation.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DevSpaceSpacing.small)
            .background(
                presentation.color.opacity(0.1),
                in: RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control)
                    .strokeBorder(
                        presentation.color.opacity(0.24),
                        lineWidth: DevSpaceStrokeWidth.hairline
                    )
            }
            .padding(.top, DevSpaceSpacing.small)
    }

    private func workspaceSteps(_ snapshot: WorkspaceSnapshot) -> some View {
        VStack(spacing: 0) {
            WorkspaceStepRow(
                number: 1,
                systemImage: "link",
                title: appLanguage.localized("workspace.section.dependencies"),
                detail: dependencySummary(snapshot.services),
                status: aggregateHealth(
                    snapshot.services.filter { $0.kind == .dependency }
                ),
                showsConnector: true
            )

            WorkspaceStepRow(
                number: 2,
                systemImage: "shippingbox",
                title: appLanguage.localized("workspace.section.application"),
                detail: applicationSummary(snapshot.services),
                status: aggregateHealth(
                    snapshot.services.filter { $0.kind == .application }
                ),
                showsConnector: true
            )

            addressStep(snapshot)
        }
        .padding(.top, DevSpaceSpacing.small)
    }

    private func addressStep(_ snapshot: WorkspaceSnapshot) -> some View {
        let url = primaryURL(from: snapshot)

        return VStack(spacing: 0) {
            WorkspaceStepRow(
                number: 3,
                systemImage: "globe",
                title: appLanguage.localized("workspace.section.address"),
                detail: url == nil
                    ? appLanguage.localized("workspace.address.unavailable")
                    : appLanguage.localized("workspace.address.available"),
                status: url == nil ? .offline : .ready,
                showsConnector: false,
                trailingSystemImage: isAddressExpanded ? "chevron.up" : "chevron.down"
            ) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    isAddressExpanded.toggle()
                }
            }

            if isAddressExpanded, let url {
                VStack(spacing: DevSpaceSpacing.small) {
                    HStack(spacing: DevSpaceSpacing.small) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.callout.monospaced())
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            copyText(url.absoluteString)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(
                            DevSpaceActionButtonStyle(
                                role: .quiet,
                                fillsWidth: false
                            )
                        )
                        .help(Text("workspace.action.copy-address"))
                        .accessibilityLabel(Text("workspace.action.copy-address"))
                    }

                    HStack(spacing: DevSpaceSpacing.small) {
                        Button {
                            openExternalURL(url)
                        } label: {
                            Label(
                                "workspace.action.open-api",
                                systemImage: "safari"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            DevSpaceActionButtonStyle(role: .primary)
                        )
                        .keyboardShortcut(.return, modifiers: [])
                        .accessibilityIdentifier("menuBar.openPrimaryURL")

                        Button {
                            openProjectFolder(store.project.rootDirectory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(
                            DevSpaceActionButtonStyle(
                                role: .secondary,
                                fillsWidth: false
                            )
                        )
                        .help(Text("workspace.action.reveal-project"))
                        .accessibilityLabel(Text("workspace.action.reveal-project"))
                    }
                }
                .padding(DevSpaceSpacing.small)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: DevSpaceCornerRadius.control)
                        .strokeBorder(
                            Color.primary.opacity(0.1),
                            lineWidth: DevSpaceStrokeWidth.hairline
                        )
                }
                .padding(.leading, 40)
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: DevSpaceSpacing.small) {
            VStack(alignment: .leading, spacing: 1) {
                Text("workspace.snapshot.updated-at")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let snapshot {
                    Text(snapshot.observedAt, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if snapshot?.origin == .preview {
                Label("workspace.preview-data", systemImage: "hammer")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: openWorkspace) {
                Label("workspace.action.open", systemImage: "folder")
            }
            .buttonStyle(
                DevSpaceActionButtonStyle(
                    role: .quiet,
                    fillsWidth: false
                )
            )
        }
        .padding(.top, DevSpaceSpacing.small)
    }

    private var snapshot: WorkspaceSnapshot? {
        store.currentSnapshot
    }

    private var stateMessage: WorkspaceStateMessage? {
        switch store.state {
        case let .degraded(_, message), let .failed(message):
            message
        case .idle, .refreshing, .ready:
            nil
        }
    }

    private var currentLifecycle: WorkspaceLifecycle? {
        switch store.state {
        case .idle, .failed:
            nil
        case let .refreshing(previous):
            previous?.lifecycle ?? .starting
        case let .ready(snapshot), let .degraded(snapshot, _):
            snapshot.lifecycle
        }
    }

    private func primaryURL(from snapshot: WorkspaceSnapshot) -> URL? {
        guard
            let port = snapshot.services.first(where: {
                $0.kind == .application && $0.health == .healthy
            })?.port
        else {
            return nil
        }

        return URL(string: "http://localhost:\(port)")
    }

    private func dependencySummary(_ services: [ServiceSummary]) -> String {
        let dependencies = services
            .filter { $0.kind == .dependency }
            .map(\.name)

        return dependencies.isEmpty
            ? appLanguage.localized("workspace.dependencies.none")
            : dependencies.joined(separator: " + ")
    }

    private func applicationSummary(_ services: [ServiceSummary]) -> String {
        guard let service = services.first(where: { $0.kind == .application }) else {
            return appLanguage.localized("workspace.application.none")
        }

        guard let port = service.port else {
            return service.name
        }

        return "\(service.name) · \(port)"
    }

    private func aggregateHealth(
        _ services: [ServiceSummary]
    ) -> DevSpaceSemanticStatus {
        guard !services.isEmpty else {
            return .offline
        }
        if services.contains(where: { $0.health == .unhealthy }) {
            return .failed
        }
        if services.contains(where: { $0.health == .starting }) {
            return .inProgress
        }
        if services.allSatisfy({ $0.health == .healthy }) {
            return .ready
        }
        if services.contains(where: { $0.health == .stopped }) {
            return .needsAttention
        }
        return .offline
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

private struct LifecycleStageView: View {
    let title: String
    let systemImage: String
    let color: Color
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: DevSpaceSpacing.xSmall) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                .frame(width: 25, height: 25)
                .background(
                    isCurrent ? color : Color.secondary.opacity(0.15),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .strokeBorder(
                            isCurrent ? color.opacity(0.42) : Color.clear,
                            lineWidth: 3
                        )
                }
            Text(title)
                .font(.caption2)
                .foregroundStyle(isCurrent ? color : .secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 60)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

private struct WorkspaceStepRow: View {
    @Environment(\.appLanguage) private var appLanguage

    let number: Int
    let systemImage: String
    let title: String
    let detail: String
    let status: DevSpaceSemanticStatus
    let showsConnector: Bool
    var trailingSystemImage: String?
    var action: (() -> Void)?

    init(
        number: Int,
        systemImage: String,
        title: String,
        detail: String,
        status: DevSpaceSemanticStatus,
        showsConnector: Bool,
        trailingSystemImage: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.number = number
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
        self.status = status
        self.showsConnector = showsConnector
        self.trailingSystemImage = trailingSystemImage
        self.action = action
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var rowContent: some View {
        HStack(spacing: DevSpaceSpacing.medium) {
                ZStack(alignment: .top) {
                    if showsConnector {
                        Rectangle()
                            .fill(status.token.color.opacity(0.38))
                            .frame(width: 1, height: 58)
                            .offset(y: 22)
                    }

                    Text(String(number))
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 25, height: 25)
                        .background(status.token.color, in: Circle())
                }
                .frame(width: 25, height: 50, alignment: .top)

                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(
                        Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: DevSpaceCornerRadius.compact)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Label(
                    status.canonicalLabel(in: appLanguage),
                    systemImage: status.token.systemImage
                )
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(status.token.color)
                .lineLimit(1)

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
    }
}
