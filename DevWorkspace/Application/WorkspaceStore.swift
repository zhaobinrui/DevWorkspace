import Foundation
import Observation
import Darwin

enum WorkspaceStateMessage: Equatable, Sendable {
    case restoredSnapshot
    case refreshCancelled
    case sourceReportedStale
    case partialRead
    case provider(String)

    func localized(in language: AppLanguage) -> String {
        switch self {
        case .restoredSnapshot:
            language.localized("workspace.message.restored-snapshot")
        case .refreshCancelled:
            language.localized("workspace.message.refresh-cancelled")
        case .sourceReportedStale:
            language.localized("workspace.message.source-reported-stale")
        case .partialRead:
            language.localized("workspace.message.partial-read")
        case let .provider(message):
            message
        }
    }
}

@MainActor
@Observable
final class WorkspaceStore {
    enum State: Equatable, Sendable {
        case idle
        case refreshing(previous: WorkspaceSnapshot?)
        case ready(WorkspaceSnapshot)
        case degraded(snapshot: WorkspaceSnapshot, message: WorkspaceStateMessage)
        case failed(message: WorkspaceStateMessage)
    }

    private(set) var project: ProjectReference?
    private(set) var state: State = .idle
    private(set) var catalog = ProjectCatalog()
    private(set) var userProcesses: SourceReading<[ListeningProcess]>?
    private(set) var isRefreshingUserProcesses = false
    private(set) var projectIssue: LocalReadFailure?
    private(set) var catalogLoadBlocked = false
    private(set) var isAddingProject = false
    private(set) var pendingRelocation: ProjectReference?

    private let catalogRepository: (any ProjectCatalogPersisting)?
    private let rootResolver: any ProjectRootResolving
    private let processInspector: any ProcessInspecting
    private var selectionRevision = 0
    private(set) var discovery: SourceReading<ProjectDiscovery>?
    private(set) var isDiscovering = false
    private var discoveryRevision = 0
    private let configurationReader: any ProjectConfigurationReading

    private let provider: any WorkspaceSnapshotProviding

    init(
        project: ProjectReference? = nil,
        provider: any WorkspaceSnapshotProviding,
        restoredSnapshot: WorkspaceSnapshot? = nil,
        catalogRepository: (any ProjectCatalogPersisting)? = nil,
        rootResolver: any ProjectRootResolving = LocalProjectRootResolver(),
        processInspector: any ProcessInspecting = NativeProcessInspector(),
        configurationReader: any ProjectConfigurationReading = LocalProjectConfigurationReader()
    ) {
        self.project = project
        self.provider = provider
        self.catalogRepository = catalogRepository
        self.rootResolver = rootResolver
        self.processInspector = processInspector
        self.configurationReader = configurationReader
        catalog.projects = project.map { [$0] } ?? []
        catalog.selectedID = project?.id

        userProcesses = restoredSnapshot?.readings?.ports
        if let restoredSnapshot {
            // 磁盘恢复的数据只能作为上一次可信状态展示，未经本次进程重新采集不能标记为实时。
            state = .degraded(
                snapshot: restoredSnapshot.markedStale(),
                message: .restoredSnapshot
            )
        } else {
            state = .idle
        }
        if catalogRepository != nil { reloadCatalog() }
    }

    func reloadCatalog() {
        do {
            if let loaded = try catalogRepository?.load() {
                catalog = loaded
                activate(loaded.projects.first { $0.id == loaded.selectedID })
            }
            catalogLoadBlocked = false
            projectIssue = nil
        } catch {
            // Keep a corrupt or newer catalog intact. Adding must not silently overwrite unrecoverable data.
            catalogLoadBlocked = true
            projectIssue = .classify(error)
        }
    }

    func addProject(at directory: URL) async {
        guard !isAddingProject, !catalogLoadBlocked else { return }
        isAddingProject = true
        pendingRelocation = nil
        defer { isAddingProject = false }
        do {
            let candidate = try await rootResolver.project(at: directory)
            try Task.checkCancellation()
            var updated = catalog
            if let existing = updated.projects.first(where: { $0.id == candidate.id || $0.rootDirectory == candidate.rootDirectory }) {
                guard existing.identity.relationship(to: candidate.identity) == .sameProject else {
                    if existing.id == candidate.id { pendingRelocation = candidate }
                    throw LocalReadFailure(kind: .identityConflict)
                }
                updated.selectedID = existing.id
            } else {
                updated.projects.append(candidate)
                updated.selectedID = candidate.id
            }
            try persist(updated)
            activate(catalog.projects.first { $0.id == catalog.selectedID })
        } catch is CancellationError { }
        catch { projectIssue = .classify(error) }
    }

    func selectProject(_ id: ProjectIdentifier) {
        guard !catalogLoadBlocked, catalog.projects.contains(where: { $0.id == id }) else { return }
        do {
            var updated = catalog
            updated.selectedID = id
            try persist(updated)
            activate(catalog.projects.first { $0.id == id })
        } catch { projectIssue = .classify(error) }
    }

    func confirmRelocation() {
        guard !catalogLoadBlocked, let candidate = pendingRelocation,
              let index = catalog.projects.firstIndex(where: { $0.id == candidate.id }) else { return }
        do {
            var updated = catalog
            let identity = try updated.projects[index].identity.acceptingRootDirectory(candidate.rootDirectory)
            updated.projects[index] = ProjectReference(identity: identity, name: candidate.name)
            updated.selectedID = identity.identifier
            try persist(updated)
            pendingRelocation = nil
            activate(catalog.projects[index])
        } catch { projectIssue = .classify(error) }
    }

    func cancelRelocation() { pendingRelocation = nil; projectIssue = nil }

    func removeSelectedProject() {
        guard !catalogLoadBlocked, let project else { return }
        do {
            var updated = catalog
            updated.projects.removeAll { $0.id == project.id }
            updated.bindings.removeAll { $0.projectID == project.id }
            updated.preferences.removeAll { $0.projectID == project.id }
            if updated.projects.isEmpty { updated.bindings.removeAll() }
            updated.selectedID = updated.projects.first?.id
            try persist(updated)
            activate(catalog.projects.first { $0.id == catalog.selectedID })
        } catch { projectIssue = .classify(error) }
    }

    func attribution(for process: ListeningProcess) -> ProcessAttribution {
        ProjectAttributionResolver.resolve(process, projects: catalog.projects, bindings: catalog.bindings)
    }

    var projectProcesses: [ListeningProcess] {
        guard let project else { return [] }
        return (userProcesses?.value ?? []).filter { attribution(for: $0).projectID == project.id }
    }

    func bind(_ process: ListeningProcess, to projectID: ProjectIdentifier?) async {
        guard !catalogLoadBlocked, userProcesses?.failure == nil else { return }
        do {
            let inspector = processInspector
            let identity = try await Task.detached(priority: .utility) { try inspector.inspect(pid: process.identity.pid).identity }.value
            try Task.checkCancellation()
            guard identity == process.identity, identity.userID == getuid(),
                  userProcesses?.value?.contains(where: { $0.identity == identity }) == true,
                  projectID == nil || catalog.projects.contains(where: { $0.id == projectID }) else {
                throw LocalReadFailure(kind: .processChanged)
            }
            var updated = catalog
            updated.bindings.removeAll { $0.process == identity }
            updated.bindings.append(ProcessProjectBinding(process: identity, projectID: projectID))
            try persist(updated)
        } catch is CancellationError { }
        catch { projectIssue = .classify(error) }
    }

    func resetBinding(_ process: ListeningProcess) {
        guard !catalogLoadBlocked else { return }
        do {
            var updated = catalog
            updated.bindings.removeAll { $0.process == process.identity }
            try persist(updated)
        } catch { projectIssue = .classify(error) }
    }

    func refreshUserProcesses(force: Bool = true) async {
        guard !isRefreshingUserProcesses else { return }
        isRefreshingUserProcesses = true
        defer { isRefreshingUserProcesses = false }
        do {
            if let reading = try await provider.userProcesses(force: force) {
                try Task.checkCancellation()
                receiveUserProcesses(reading)
            }
        } catch is CancellationError { }
        catch { receiveUserProcesses(.failed(error)) }
    }

    private func receiveUserProcesses(_ reading: SourceReading<[ListeningProcess]>) {
        guard userProcesses == nil || reading.attemptedAt >= userProcesses!.attemptedAt else { return }
        userProcesses = reading.retainingTrustedValue(from: userProcesses)
        guard !isRefreshing, let snapshot = currentSnapshot, var readings = snapshot.readings,
              snapshot.freshness == .current else { return }
        readings.ports = userProcesses!
        let updated = WorkspaceSnapshot(project: snapshot.project, lifecycle: snapshot.lifecycle, git: snapshot.git,
                                        services: snapshot.services, observedAt: snapshot.observedAt,
                                        freshness: snapshot.freshness, origin: snapshot.origin, readings: readings)
        state = readings.hasFailure ? .degraded(snapshot: updated, message: .partialRead) : .ready(updated)
    }

    var displayReadings: WorkspaceReadings? {
        guard var readings = currentSnapshot?.readings else { return nil }
        readings.ports = userProcesses ?? readings.ports
        return readings
    }

    func preferences(for id: ProjectIdentifier) -> ProjectPreferences {
        catalog.preferences.first { $0.projectID == id } ?? ProjectPreferences(projectID: id)
    }

    func savePreferences(_ preferences: ProjectPreferences) throws {
        guard !catalogLoadBlocked, catalog.projects.contains(where: { $0.id == preferences.projectID }) else {
            throw LocalReadFailure(kind: .corruptStorage)
        }
        guard preferences.links.allSatisfy({ ProjectURLPolicy.validated($0.url.absoluteString) != nil }) else {
            throw ProjectActionFailure.invalidURL
        }
        guard preferences.profile?.isValid() != false else { throw ProfileFailure.invalidProfile }
        var updated = catalog
        updated.preferences.removeAll { $0.projectID == preferences.projectID }
        updated.preferences.append(preferences)
        try persist(updated)
    }

    func saveProfileDraft(_ draft: ProjectProfile, for id: ProjectIdentifier) throws {
        guard draft.isValid() else { throw ProfileFailure.invalidProfile }
        var preferences = preferences(for: id)
        var untrusted = draft
        untrusted.trust = nil
        preferences.profile = untrusted.isEmpty ? nil : untrusted
        try savePreferences(preferences)
    }

    func profileTrustStatus(for project: ProjectReference) -> ProfileTrustStatus {
        guard let profile = preferences(for: project.id).profile else { return .absent }
        guard profile.trust != nil else { return .draft }
        guard let reading = discovery, reading.failure == nil, let value = reading.value,
              !value.issues.contains(where: { $0.source.hasPrefix("package.json") }),
              profile.commands.isEmpty || value.packageDigest != nil else { return .needsScan }
        return profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                 packageDigest: value.packageDigest)
            ? .trusted : .sourceChanged
    }

    func trustProfile(for id: ProjectIdentifier, reviewed: ProjectProfile,
                      packageDigest: String?) async throws {
        guard let project, project.id == id, !catalogLoadBlocked,
              preferences(for: id).profile == reviewed else { throw ProfileFailure.projectChanged }
        let revision = selectionRevision
        // Re-read before recording trust so a changed repository cannot reuse an old preview.
        let fresh = try await configurationReader.read(root: project.rootDirectory)
        try Task.checkCancellation()
        guard revision == selectionRevision, self.project?.id == id,
              preferences(for: id).profile == reviewed else { throw ProfileFailure.projectChanged }
        guard !fresh.issues.contains(where: { $0.source.hasPrefix("package.json") }),
              fresh.packageDigest == packageDigest else { throw ProfileFailure.reviewChanged }
        guard reviewed.commands.allSatisfy({ command in
            fresh.packageScripts.contains(where: { $0.name == command.scriptName })
        }) else { throw ProfileFailure.missingScript }
        guard let fingerprint = reviewed.fingerprint(projectID: id, root: project.rootDirectory,
                                                    packageDigest: fresh.packageDigest) else {
            throw ProfileFailure.invalidProfile
        }
        var preferences = preferences(for: id)
        var trusted = reviewed
        trusted.trust = ProfileTrust(fingerprint: fingerprint, acceptedAt: .now)
        preferences.profile = trusted
        try savePreferences(preferences)
    }

    func discoverConfiguration() async {
        guard let project, !isDiscovering else { return }
        let revision = discoveryRevision
        let previous = discovery
        isDiscovering = true
        defer { if revision == discoveryRevision { isDiscovering = false } }
        do {
            var value = try await configurationReader.read(root: project.rootDirectory)
            try Task.checkCancellation()
            guard revision == discoveryRevision else { return }
            if let issue = value.issues.first {
                let failedFiles = Set(value.issues.map { $0.source.components(separatedBy: " · ")[0] })
                // Preserve affected files only; a successful empty scan must still remove deleted entries.
                value.links.removeAll { failedFiles.contains($0.source.components(separatedBy: " · ")[0]) }
                value.links += (previous?.value?.links ?? []).filter { failedFiles.contains($0.source.components(separatedBy: " · ")[0]) }
                value.dockerFiles += (previous?.value?.dockerFiles ?? []).filter { failedFiles.contains($0) }
                if failedFiles.contains("package.json") {
                    value.packageScripts = previous?.value?.packageScripts ?? []
                    value.packageDigest = previous?.value?.packageDigest
                }
                discovery = SourceReading(value: value, checkedAt: previous?.checkedAt,
                                          attemptedAt: .now, failure: issue.failure)
            } else {
                discovery = .success(value)
            }
        } catch is CancellationError { }
        catch {
            guard revision == discoveryRevision else { return }
            discovery = SourceReading.failed(error).retainingTrustedValue(from: previous)
        }
    }

    private func persist(_ updated: ProjectCatalog) throws {
        try catalogRepository?.save(updated)
        catalog = updated
        projectIssue = nil
    }

    private func activate(_ selected: ProjectReference?) {
        guard project != selected else { return }
        selectionRevision += 1
        discoveryRevision += 1
        discovery = nil
        isDiscovering = false
        project = selected
        state = .idle
    }

    var currentSnapshot: WorkspaceSnapshot? {
        switch state {
        case .idle, .failed:
            nil
        case let .refreshing(previous):
            previous
        case let .ready(snapshot), let .degraded(snapshot, _):
            snapshot
        }
    }

    var isRefreshing: Bool {
        if case .refreshing = state {
            true
        } else {
            false
        }
    }

    var shouldLoad: Bool {
        if case .idle = state {
            project != nil
        } else {
            false
        }
    }

    func refresh(forceProcessRefresh: Bool = true) async {
        guard !isRefreshing, let project else {
            return
        }

        // 刷新期间保留旧快照，避免菜单栏短暂退回空状态；新结果成功后再原子替换。
        let previous = currentSnapshot
        let revision = selectionRevision
        state = .refreshing(previous: previous)

        do {
            var snapshot = try await provider.snapshot(for: project, refreshProcesses: forceProcessRefresh)
            try Task.checkCancellation()
            guard revision == selectionRevision else { return }
            guard snapshot.project.id == project.id else { throw LocalReadFailure(kind: .invalidOutput) }
            if let readings = snapshot.readings {
                receiveUserProcesses(readings.ports)
                var merged = readings.retainingTrustedValues(from: previous?.readings)
                merged.ports = userProcesses ?? merged.ports
                snapshot = WorkspaceSnapshot(project: project, lifecycle: .observed, git: merged.git.value,
                                             services: [], observedAt: snapshot.observedAt, freshness: .current,
                                             origin: .local, readings: merged)
                state = merged.hasFailure ? .degraded(snapshot: snapshot, message: .partialRead) : .ready(snapshot)
                return
            }
            // 数据源可以返回历史缓存；即使调用成功，也不能把明确标记为 stale 的快照
            // 提升为 Ready，否则会破坏“旧数据不得伪装为实时状态”的可信边界。
            state = snapshot.freshness == .current
                ? .ready(snapshot)
                : .degraded(
                    snapshot: snapshot,
                    message: .sourceReportedStale
                )
        } catch is CancellationError {
            guard revision == selectionRevision else { return }
            // 取消是调用方主动结束工作，不等同于数据源故障，因此恢复原可信状态且不制造错误。
            if let previous {
                state = previous.readings?.hasFailure == true
                    ? .degraded(snapshot: previous, message: .partialRead)
                    : previous.freshness == .stale
                    ? .degraded(snapshot: previous, message: .refreshCancelled)
                    : .ready(previous)
            } else {
                state = .idle
            }
        } catch {
            guard revision == selectionRevision else { return }
            // 采集失败时继续展示最后一次可信数据，但明确降级为 stale，避免旧数据伪装成实时状态。
            if let previous {
                state = .degraded(
                    snapshot: previous.markedStale(),
                    message: .provider(error.localizedDescription)
                )
            } else {
                state = .failed(message: .provider(error.localizedDescription))
            }
        }
    }
}
