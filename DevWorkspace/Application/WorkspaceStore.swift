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
    private(set) var projectIssue: LocalReadFailure?
    private(set) var catalogLoadBlocked = false
    private(set) var isAddingProject = false
    private(set) var pendingRelocation: ProjectReference?

    private let catalogRepository: (any ProjectCatalogPersisting)?
    private let rootResolver: any ProjectRootResolving
    private let processInspector: any ProcessInspecting
    private var selectionRevision = 0

    private let provider: any WorkspaceSnapshotProviding

    init(
        project: ProjectReference? = nil,
        provider: any WorkspaceSnapshotProviding,
        restoredSnapshot: WorkspaceSnapshot? = nil,
        catalogRepository: (any ProjectCatalogPersisting)? = nil,
        rootResolver: any ProjectRootResolving = LocalProjectRootResolver(),
        processInspector: any ProcessInspecting = NativeProcessInspector()
    ) {
        self.project = project
        self.provider = provider
        self.catalogRepository = catalogRepository
        self.rootResolver = rootResolver
        self.processInspector = processInspector
        catalog.projects = project.map { [$0] } ?? []
        catalog.selectedID = project?.id

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
        return (currentSnapshot?.readings?.ports.value ?? []).filter { attribution(for: $0).projectID == project.id }
    }

    func bind(_ process: ListeningProcess, to projectID: ProjectIdentifier?) async {
        guard !catalogLoadBlocked, currentSnapshot?.readings?.ports.failure == nil else { return }
        do {
            let inspector = processInspector
            let identity = try await Task.detached(priority: .utility) { try inspector.inspect(pid: process.identity.pid).identity }.value
            try Task.checkCancellation()
            guard identity == process.identity, identity.userID == getuid(),
                  currentSnapshot?.readings?.ports.value?.contains(where: { $0.identity == identity }) == true,
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

    private func persist(_ updated: ProjectCatalog) throws {
        try catalogRepository?.save(updated)
        catalog = updated
        projectIssue = nil
    }

    private func activate(_ selected: ProjectReference?) {
        guard project != selected else { return }
        selectionRevision += 1
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

    func refresh() async {
        guard !isRefreshing, let project else {
            return
        }

        // 刷新期间保留旧快照，避免菜单栏短暂退回空状态；新结果成功后再原子替换。
        let previous = currentSnapshot
        let revision = selectionRevision
        state = .refreshing(previous: previous)

        do {
            var snapshot = try await provider.snapshot(for: project)
            try Task.checkCancellation()
            guard revision == selectionRevision else { return }
            guard snapshot.project.id == project.id else { throw LocalReadFailure(kind: .invalidOutput) }
            if let readings = snapshot.readings {
                let merged = readings.retainingTrustedValues(from: previous?.readings)
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
