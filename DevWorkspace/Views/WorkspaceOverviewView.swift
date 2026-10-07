import SwiftUI

/// The workspace window shows summaries first; the menu-bar presentation keeps its own compact layout.
struct WorkspaceOverviewView: View {
    @Environment(\.appLanguage) private var language
    @Bindable var store: WorkspaceStore
    var showsUserProcesses = false

    var body: some View {
        if showsUserProcesses {
            if let reading = store.userProcesses {
                portsSection(reading)
            } else {
                ContentUnavailableView("processes.not-loaded", systemImage: "network", description: Text("processes.scope"))
            }
        } else if let readings = store.displayReadings {
            VStack(alignment: .leading, spacing: 20) {
                gitSection(readings.git)
                portsSection(readings.ports)
                if let compose = readings.compose { composeSection(compose) }
            }
        } else if let reading = store.userProcesses {
            // Keep cached project attribution visible while its independent Git request is loading.
            portsSection(reading)
        }
    }

    private func gitSection(_ reading: SourceReading<GitSummary>) -> some View {
        WorkspacePanel {
            sectionHeader("Git", symbol: "point.3.connected.trianglepath.dotted", reading: reading)
            sourceFailure(reading)
            if let git = reading.value {
                HStack(spacing: 10) {
                    Text(git.branch).font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if git.isDetached { Text("git.detached").font(.caption).foregroundStyle(.orange) }
                    if git.isUnborn { Text("git.unborn").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(spacing: 0) {
                    metric("dashboard.changed-files", value: String(git.changedFileCount), symbol: "doc.text", emphasized: git.changedFileCount > 0)
                    Divider().frame(height: 42).padding(.horizontal, 16)
                    metric("dashboard.ahead", value: git.hasDivergence && git.upstream != nil ? String(git.commitsAhead) : "—", symbol: "arrow.up")
                    Divider().frame(height: 42).padding(.horizontal, 16)
                    metric("dashboard.behind", value: git.hasDivergence && git.upstream != nil ? String(git.commitsBehind) : "—", symbol: "arrow.down")
                }
                .padding(16)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    if let upstream = git.upstream {
                        Label(upstream, systemImage: "arrow.triangle.branch").lineLimit(2)
                        if !git.hasDivergence { Text("git.divergence-unavailable").foregroundStyle(.orange) }
                    } else { Text("git.no-upstream") }
                    Text("git.local-tracking-note").font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            } else if reading.failure == nil {
                quietState("git.not-repository", symbol: "folder", detail: "dashboard.git-empty-note")
            }
        }
    }

    private func metric(_ title: LocalizedStringKey, value: String, symbol: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(emphasized ? Color.accentColor : .primary)
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func composeSection(_ reading: SourceReading<ComposeProjectStatus>) -> some View {
        WorkspacePanel {
            sectionHeader("docker.compose.title", symbol: "shippingbox", reading: reading)
            Text("docker.compose.readonly").font(.system(size: 10)).foregroundStyle(.secondary)
            sourceFailure(reading)
            if let status = reading.value {
                if reading.failure != nil {
                    Text("docker.compose.stale-note").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Label(status.configurationName, systemImage: "doc.text").textSelection(.enabled)
                    if let projectName = status.projectName {
                        Label(projectName, systemImage: "square.stack.3d.up").textSelection(.enabled)
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if status.containers.isEmpty {
                    quietState(reading.failure == nil ? "docker.compose.empty" : "docker.compose.last-empty",
                               symbol: "shippingbox", detail: "docker.compose.empty-note")
                } else {
                    VStack(spacing: 0) {
                        ForEach(status.containers) { container in
                            composeRow(container, stale: reading.failure != nil)
                            if container.id != status.containers.last?.id { Divider().padding(.vertical, 10) }
                        }
                    }
                }
            }
        }
    }

    private func composeRow(_ container: ComposeContainer, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(container.serviceName).font(.system(size: 13, weight: .semibold))
                Spacer()
                Label(composeStatusKey(container), systemImage: composeStatusSymbol(container))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(composeStatusColor(container, stale: stale))
            }
            Text(String(format: language.localized("docker.compose.evidence"),
                        container.projectName, String(container.id.prefix(12))))
                .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(container.ports, id: \.self) { port in
                Text("\(port.address):\(String(port.published)) → \(String(port.target))/\(port.transport)")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func composeStatusKey(_ container: ComposeContainer) -> LocalizedStringKey {
        if container.isUnhealthy { return "docker.compose.unhealthy" }
        switch container.state {
        case .running:
            switch container.health {
            case .healthy: return "docker.compose.healthy"
            case .starting: return "docker.compose.starting"
            case .unhealthy: return "docker.compose.unhealthy"
            case nil: return "docker.compose.running-unchecked"
            }
        case .restarting: return "docker.compose.restarting"
        case .exited: return "docker.compose.stopped"
        case .created: return "docker.compose.created"
        case .paused: return "docker.compose.paused"
        case .removing: return "docker.compose.removing"
        case .dead: return "docker.compose.dead"
        }
    }

    private func composeStatusSymbol(_ container: ComposeContainer) -> String {
        if container.isUnhealthy { return "exclamationmark.triangle.fill" }
        switch container.state {
        case .running: return container.health == .healthy ? "checkmark.circle.fill" : "circle.dotted"
        case .restarting: return "arrow.clockwise"
        case .exited, .created, .paused, .removing, .dead: return "stop.circle"
        }
    }

    private func composeStatusColor(_ container: ComposeContainer, stale: Bool) -> Color {
        if stale { return .secondary }
        if container.isUnhealthy { return .orange }
        switch container.state {
        case .running: return container.health == .healthy ? .green : .secondary
        case .restarting: return .orange
        case .exited, .created, .paused, .removing, .dead: return .secondary
        }
    }

    private func portsSection(_ reading: SourceReading<[ListeningProcess]>) -> some View {
        WorkspacePanel {
            sectionHeader(showsUserProcesses ? "processes.title" : "ports.title", symbol: "network", reading: reading)
            Text("ports.scope").font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            sourceFailure(reading)
            if let all = reading.value {
                let processes = showsUserProcesses ? all : store.projectProcesses
                if processes.isEmpty {
                    quietState(reading.failure == nil ? (showsUserProcesses ? "processes.empty" : "ports.project-empty") : "ports.last-empty", symbol: "network", detail: showsUserProcesses ? "processes.scope" : "dashboard.ports-empty-note")
                } else {
                    HStack {
                        Text("dashboard.processes").font(.system(size: 10, weight: .medium))
                        Spacer()
                        Text(String(format: language.localized("dashboard.process-count"), processes.count))
                            .font(.system(size: 10)).monospacedDigit()
                    }.foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(processes) { process in
                            processRow(process, canBind: reading.failure == nil)
                            if process.id != processes.last?.id { Divider().padding(.vertical, 12) }
                        }
                    }
                }
                let unresolved = all.filter { $0.directoryFailure != nil && store.attribution(for: $0) == .unassigned }
                if !unresolved.isEmpty {
                    Label("ports.unresolved-note", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

            }
        }
    }

    private func processRow(_ process: ListeningProcess, canBind: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(process.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([process.runtime, "PID \(process.identity.pid)"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                WorkspaceOverflowMenu(title: "ports.attribution") {
                    ForEach(store.catalog.projects) { project in
                        Button(project.name) { Task { await store.bind(process, to: project.id) } }
                    }
                    Button("ports.exclude") { Task { await store.bind(process, to: nil) } }
                    Button("ports.automatic") { store.resetBinding(process) }
                }.disabled(!canBind)
            }
            if showsUserProcesses {
                Text(attributionText(process)).font(.caption).foregroundStyle(.secondary)
            }
            // Adaptive columns keep every endpoint visible without one long, truncated socket summary.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(process.sockets, id: \.self) { socket in
                    HStack(spacing: 6) {
                        Text(":\(String(socket.port))").font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(socket.transport.rawValue).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        Text(socket.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    .help("\(socket.transport.rawValue) \(socket.address):\(socket.port)")
                }
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 7) {
                    detail("dashboard.executable", value: process.identity.executablePath)
                    detail("dashboard.owner", value: "\(process.userName) · UID \(process.identity.userID)")
                    if let directory = process.workingDirectory { detail("dashboard.directory", value: directory.path) }
                    Text(attributionText(process)).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8).padding(.bottom, 4)
            } label: { Text("dashboard.process-details").font(.system(size: 10)) }
            .tint(.secondary)
            if let failure = process.directoryFailure {
                // A hidden disclosure must never hide a failure to establish process ownership.
                Label(failure.localized(in: language), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func detail(_ key: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionHeader<Value>(_ title: LocalizedStringKey, symbol: String, reading: SourceReading<Value>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                readingTime(reading)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                readingTime(reading)
            }
        }
    }

    @ViewBuilder private func readingTime<Value>(_ reading: SourceReading<Value>) -> some View {
        if let date = reading.checkedAt {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text(LocalizedStringKey(reading.failure == nil ? "workspace.snapshot.updated-at" : "workspace.snapshot.last-trusted-at"))
                Text(date, format: .dateTime.month().day().hour().minute())
            }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
        }
    }

    @ViewBuilder private func sourceFailure<Value>(_ reading: SourceReading<Value>) -> some View {
        if let failure = reading.failure {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(failure.localized(in: language))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }.font(.system(size: 12, weight: .medium))
                HStack(spacing: 5) {
                    Text("local.attempted-at")
                    Text(reading.attemptedAt, format: .dateTime.month().day().hour().minute().second())
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func quietState(_ title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
    }

    private func attributionText(_ process: ListeningProcess) -> String {
        let attribution = store.attribution(for: process)
        let name = store.catalog.projects.first { $0.id == attribution.projectID }?.name ?? ""
        switch attribution {
        case .directory: return String(format: language.localized("ports.attribution-directory"), name)
        case .manual: return String(format: language.localized("ports.attribution-manual"), name)
        case .excluded: return language.localized("ports.attribution-excluded")
        case .unassigned: return language.localized("ports.attribution-unknown")
        }
    }
}

private struct WorkspacePanel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: DevSpaceCornerRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: DevSpaceCornerRadius.panel)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}
