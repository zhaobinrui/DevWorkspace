import SwiftUI

struct LocalWorkspaceReadingsView: View {
    @Environment(\.appLanguage) private var language
    @Bindable var store: WorkspaceStore
    var compact = false

    var body: some View {
        if let readings = store.currentSnapshot?.readings {
            VStack(alignment: .leading, spacing: DevSpaceSpacing.large) {
                GroupBox("Git") {
                    VStack(alignment: .leading, spacing: DevSpaceSpacing.small) {
                        sourceMetadata(readings.git)
                        if let git = readings.git.value {
                            HStack {
                                Label(git.branch, systemImage: "point.3.connected.trianglepath.dotted")
                                if git.isDetached { Text("git.detached").foregroundStyle(.orange) }
                                if git.isUnborn { Text("git.unborn").foregroundStyle(.secondary) }
                            }
                            Text(String(format: language.localized("git.changed-format"), git.changedFileCount))
                            if let upstream = git.upstream {
                                Text(upstream)
                                if git.hasDivergence {
                                    Text("↑\(git.commitsAhead) ↓\(git.commitsBehind)")
                                } else {
                                    // An absent branch.ab can mean the upstream ref is missing locally, not zero divergence.
                                    Text("git.divergence-unavailable").foregroundStyle(.secondary)
                                }
                                if !compact { Text("git.local-tracking-note").font(.caption).foregroundStyle(.secondary) }
                            } else { Text("git.no-upstream").foregroundStyle(.secondary) }
                        } else if readings.git.failure == nil { Text("git.not-repository").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("ports.title") {
                    VStack(alignment: .leading, spacing: DevSpaceSpacing.small) {
                        sourceMetadata(readings.ports)
                        Text("ports.scope").font(.caption).foregroundStyle(.secondary)
                        if readings.ports.value != nil {
                            if store.projectProcesses.isEmpty {
                                Text(LocalizedStringKey(readings.ports.failure == nil ? "ports.project-empty" : "ports.last-empty"))
                                    .foregroundStyle(.secondary)
                            } else if compact {
                                ForEach(Array(store.projectProcesses.prefix(3))) { process in
                                    Text("\(process.name) · PID \(process.identity.pid) · \(socketSummary(process))")
                                        .font(.caption).lineLimit(2)
                                }
                                if store.projectProcesses.count > 3 { Text("ports.more-in-workspace").font(.caption) }
                            } else {
                                ForEach(store.projectProcesses) { process in processRow(process, canBind: readings.ports.failure == nil) }
                            }
                            let unresolved = (readings.ports.value ?? []).filter { $0.directoryFailure != nil && store.attribution(for: $0) == .unassigned }
                            if !unresolved.isEmpty {
                                Label("ports.unresolved-note", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if !compact {
                                let others = (readings.ports.value ?? []).filter { store.attribution(for: $0).projectID != store.project?.id }
                                if !others.isEmpty {
                                    DisclosureGroup(String(format: language.localized("ports.others-format"), others.count)) {
                                        VStack(alignment: .leading, spacing: DevSpaceSpacing.medium) {
                                            ForEach(others) { process in processRow(process, canBind: readings.ports.failure == nil) }
                                        }.padding(.top, DevSpaceSpacing.small)
                                    }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sourceMetadata<Value>(_ reading: SourceReading<Value>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = reading.failure {
                Label(failure.localized(in: language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("local.attempted-at")
                    Text(reading.attemptedAt, format: .dateTime.hour().minute().second())
                }
            }
            if let checkedAt = reading.checkedAt {
                HStack {
                    Text(LocalizedStringKey(reading.failure == nil ? "workspace.snapshot.updated-at" : "workspace.snapshot.last-trusted-at"))
                    Text(checkedAt, format: .dateTime.month().day().hour().minute().second())
                }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func processRow(_ process: ListeningProcess, canBind: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(process.name).fontWeight(.semibold)
                if !process.runtime.isEmpty { Text(process.runtime).foregroundStyle(.secondary) }
                Spacer()
                Menu("ports.attribution") {
                    if let project = store.project {
                        Button("ports.bind-current") { Task { await store.bind(process, to: project.id) } }
                    }
                    Button("ports.exclude") { Task { await store.bind(process, to: nil) } }
                    Button("ports.automatic") { store.resetBinding(process) }
                }.disabled(!canBind)
            }
            Text("PID \(process.identity.pid) · \(process.userName) (UID \(process.identity.userID)) · \(socketSummary(process))")
                .font(.callout).monospacedDigit()
            Text(process.identity.executablePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let directory = process.workingDirectory {
                Text(String(format: language.localized("ports.cwd-format"), directory.path)).font(.caption).textSelection(.enabled)
            } else if let failure = process.directoryFailure {
                Text(String(format: language.localized("ports.cwd-format"), failure.localized(in: language)))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(attributionText(process)).font(.caption).foregroundStyle(.secondary)
            Divider()
        }.padding(.vertical, 4)
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

    private func socketSummary(_ process: ListeningProcess) -> String {
        process.sockets.map { "\($0.transport.rawValue) \($0.address):\($0.port)" }.joined(separator: ", ")
    }
}
