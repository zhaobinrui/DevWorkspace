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
    private(set) var homebrewServices: SourceReading<[HomebrewServiceStatus]>?
    private(set) var isRefreshingHomebrewServices = false
    private(set) var executionPhase: ProjectExecutionPhase = .idle
    private(set) var composePhase: ComposeExecutionPhase = .idle
    private(set) var projectIssue: LocalReadFailure?
    private(set) var catalogLoadBlocked = false
    private(set) var isAddingProject = false
    private(set) var pendingRelocation: ProjectReference?

    private let catalogRepository: (any ProjectCatalogPersisting)?
    private let rootResolver: any ProjectRootResolving
    private let processInspector: any ProcessInspecting
    private var selectionRevision = 0
    private var homebrewRevision = 0
    private(set) var discovery: SourceReading<ProjectDiscovery>?
    private(set) var isDiscovering = false
    private var discoveryRevision = 0
    private let configurationReader: any ProjectConfigurationReading
    private let homebrewReader: any HomebrewServiceStatusReading
    private let readinessProbe: any ProjectReadinessProbing
    private let readinessTimeout: Duration
    private let npmExecutable: URL?
    private let composeController: any DockerComposeControlling
    private var executionTask: Task<Void, Never>?
    private var composeTask: Task<Void, Never>?
    private var ownedProcess: Process?
    private var transientManagedProcess: ManagedProjectProcess?
    private var transientComposeRun: ManagedComposeRun?

    private let provider: any WorkspaceSnapshotProviding

    init(
        project: ProjectReference? = nil,
        provider: any WorkspaceSnapshotProviding,
        restoredSnapshot: WorkspaceSnapshot? = nil,
        catalogRepository: (any ProjectCatalogPersisting)? = nil,
        rootResolver: any ProjectRootResolving = LocalProjectRootResolver(),
        processInspector: any ProcessInspecting = NativeProcessInspector(),
        configurationReader: any ProjectConfigurationReading = LocalProjectConfigurationReader(),
        homebrewReader: any HomebrewServiceStatusReading = LocalHomebrewServiceStatusReader(),
        readinessProbe: any ProjectReadinessProbing = LoopbackHTTPReadinessProbe(),
        readinessTimeout: Duration = .seconds(30),
        npmExecutable: URL? = NPMExecutableResolver.resolve(),
        composeController: any DockerComposeControlling = LocalDockerComposeController()
    ) {
        self.project = project
        self.provider = provider
        self.catalogRepository = catalogRepository
        self.rootResolver = rootResolver
        self.processInspector = processInspector
        self.configurationReader = configurationReader
        self.homebrewReader = homebrewReader
        self.readinessProbe = readinessProbe
        self.readinessTimeout = readinessTimeout
        self.npmExecutable = npmExecutable
        self.composeController = composeController
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
        guard !hasActiveControlTask else { projectIssue = .init(kind: .operationInProgress); return }
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
        guard !isAddingProject, !catalogLoadBlocked,
              !hasActiveControlTask else { projectIssue = .init(kind: .operationInProgress); return }
        isAddingProject = true
        pendingRelocation = nil
        defer { isAddingProject = false }
        do {
            let candidate = try await rootResolver.project(at: directory)
            try Task.checkCancellation()
            guard !hasActiveControlTask else { throw LocalReadFailure(kind: .operationInProgress) }
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
        guard !hasActiveControlTask else { projectIssue = .init(kind: .operationInProgress); return }
        guard !catalogLoadBlocked, catalog.projects.contains(where: { $0.id == id }) else { return }
        do {
            var updated = catalog
            updated.selectedID = id
            try persist(updated)
            activate(catalog.projects.first { $0.id == id })
        } catch { projectIssue = .classify(error) }
    }

    func confirmRelocation() {
        guard !hasActiveControlTask else { projectIssue = .init(kind: .operationInProgress); return }
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
        guard !hasActiveControlTask else { projectIssue = .init(kind: .operationInProgress); return }
        guard !catalogLoadBlocked, let project else { return }
        guard !catalog.managedProcesses.contains(where: { $0.projectID == project.id }),
              transientManagedProcess?.projectID != project.id,
              !catalog.managedComposeRuns.contains(where: { $0.projectID == project.id }),
              transientComposeRun?.projectID != project.id else {
            projectIssue = .init(kind: .activeManagedProcess)
            return
        }
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
        homebrewRevision += 1
        homebrewServices = nil
        isRefreshingHomebrewServices = false
    }

    func refreshHomebrewServices() async {
        guard !isRefreshingHomebrewServices, let project else { return }
        let names = preferences(for: project.id).profile?.homebrewServices ?? []
        guard !names.isEmpty else { homebrewServices = nil; return }
        let revision = selectionRevision
        let serviceRevision = homebrewRevision
        let previous = homebrewServices
        isRefreshingHomebrewServices = true
        defer { if serviceRevision == homebrewRevision { isRefreshingHomebrewServices = false } }
        do {
            let statuses = try await homebrewReader.read(names: names)
            try Task.checkCancellation()
            guard revision == selectionRevision, serviceRevision == homebrewRevision,
                  names == preferences(for: project.id).profile?.homebrewServices else { return }
            homebrewServices = .success(statuses)
        } catch is CancellationError { }
        catch {
            guard revision == selectionRevision, serviceRevision == homebrewRevision,
                  names == preferences(for: project.id).profile?.homebrewServices else { return }
            homebrewServices = SourceReading<[HomebrewServiceStatus]>.failed(error)
                .retainingTrustedValue(from: previous)
        }
    }

    var managedProcess: ManagedProjectProcess? {
        guard let project else { return nil }
        return transientManagedProcess?.projectID == project.id ? transientManagedProcess
            : catalog.managedProcesses.first { $0.projectID == project.id }
    }

    private var hasActiveControlTask: Bool { executionTask != nil || composeTask != nil }

    func startSelectedProject() {
        guard !hasActiveControlTask, managedProcess == nil, let project else { return }
        executionTask = Task { [weak self] in
            guard let self else { return }
            await self.performStart(project)
            self.executionTask = nil
        }
    }

    func cancelSelectedProjectStart() {
        executionTask?.cancel()
    }

    func stopSelectedProject() {
        guard !hasActiveControlTask, let project, let record = managedProcess else { return }
        executionTask = Task { [weak self] in
            guard let self else { return }
            await self.performStop(record, project: project)
            self.executionTask = nil
        }
    }

    func retryReadiness() {
        guard !hasActiveControlTask, let project, let record = managedProcess,
              let url = readinessURL(for: project.id, compose: false) else { return }
        executionTask = Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReady(record, project: project, url: url)
            self.executionTask = nil
        }
    }

    private func readinessURL(for id: ProjectIdentifier, compose: Bool) -> URL? {
        let preferences = preferences(for: id)
        let selected = compose ? preferences.profile?.composeReadinessURL
            : preferences.profile?.processReadinessURL
        return selected ?? preferences.links.map(\.url).first(where: LoopbackHTTPReadinessProbe.accepts)
    }

    private func performStart(_ project: ProjectReference) async {
        let revision = selectionRevision
        executionPhase = .validating
        do {
            guard let profile = preferences(for: project.id).profile,
                  let command = profile.commands.first(where: { $0.role == .start }),
                  profile.trust != nil else { throw ProjectExecutionFailure.noTrustedStart }
            let fresh = try await configurationReader.read(root: project.rootDirectory)
            try Task.checkCancellation()
            guard selectionRevision == revision, self.project?.id == project.id,
                  preferences(for: project.id).profile == profile else {
                throw ProfileFailure.projectChanged
            }
            guard !fresh.issues.contains(where: { $0.source.hasPrefix("package.json") }),
                  fresh.packageScripts.contains(where: { $0.name == command.scriptName }),
                  profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                    packageDigest: fresh.packageDigest,
                                    composeDigest: fresh.composeDigest) else {
                throw ProjectExecutionFailure.sourceChanged
            }
            guard let url = readinessURL(for: project.id, compose: false) else {
                throw ProjectExecutionFailure.missingReadinessURL
            }
            // A pre-existing healthy listener cannot prove that the process we are about to
            // launch became ready, and may indicate a duplicate instance of the same project.
            if (try? await readinessProbe.probe(url)) == true {
                throw ProjectExecutionFailure.endpointAlreadyReady
            }
            try Task.checkCancellation()
            guard selectionRevision == revision, self.project?.id == project.id,
                  preferences(for: project.id).profile == profile else {
                throw ProjectExecutionFailure.sourceChanged
            }
            let latest = try await configurationReader.read(root: project.rootDirectory)
            try Task.checkCancellation()
            guard latest.packageDigest == fresh.packageDigest,
                  !latest.issues.contains(where: { $0.source.hasPrefix("package.json") }) else {
                throw ProjectExecutionFailure.sourceChanged
            }
            guard let executable = npmExecutable,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ProjectExecutionFailure.executableUnavailable
            }
            executionPhase = .launching
            let process = Process()
            process.executableURL = executable
            process.arguments = ["run", command.scriptName]
            process.currentDirectoryURL = project.rootDirectory
            process.standardInput = FileHandle.nullDevice
            // Script output may include credentials; this first execution slice records only
            // lifecycle and identity, never command output or arbitrary repository content.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                                   "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "LC_ALL": "C", "npm_config_update_notifier": "false"]
            try Task.checkCancellation()
            do { try process.run() } catch { throw ProjectExecutionFailure.launchFailed }
            ownedProcess = process
            let inspected = try await identifyLaunchedProcess(process, project: project)
            let record = ManagedProjectProcess(projectID: project.id, rootDirectory: project.rootDirectory,
                                               scriptName: command.scriptName, identity: inspected.identity,
                                               launchedAt: .now)
            transientManagedProcess = record
            var updated = catalog
            updated.managedProcesses.removeAll { $0.projectID == project.id }
            updated.managedProcesses.append(record)
            do { try persist(updated); transientManagedProcess = nil }
            catch { throw ProjectExecutionFailure.persistenceFailed }
            try Task.checkCancellation()
            await waitUntilReady(record, project: project, url: url)
        } catch is CancellationError {
            if let record = managedProcess { await performStop(record, project: project) }
            else { await cleanupUnregisteredProcess(project: project) }
            if managedProcess == nil { executionPhase = .cancelled }
        } catch let failure as ProjectExecutionFailure {
            if managedProcess == nil { await cleanupUnregisteredProcess(project: project) }
            executionPhase = .failed(failure)
        } catch {
            if managedProcess == nil { await cleanupUnregisteredProcess(project: project) }
            executionPhase = .failed(.sourceChanged)
        }
    }

    private func cleanupUnregisteredProcess(project: ProjectReference) async {
        guard let process = ownedProcess, process.isRunning,
              let inspected = try? processInspector.inspect(pid: process.processIdentifier),
              inspected.identity.userID == getuid(),
              inspected.workingDirectory == project.rootDirectory else { return }
        // Launch failed before persistence. The live Process handle and native identity
        // still have to agree before signalling even this just-created child.
        guard Darwin.kill(inspected.identity.pid, SIGTERM) == 0 else { return }
        for _ in 0..<30 where process.isRunning {
            await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
        if !process.isRunning { ownedProcess = nil }
    }

    private func identifyLaunchedProcess(_ process: Process, project: ProjectReference) async throws -> InspectedProcess {
        var last: ProcessIdentity?
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard process.isRunning else { throw ProjectExecutionFailure.processExited }
            if let inspected = try? processInspector.inspect(pid: process.processIdentifier),
               inspected.identity.userID == getuid(),
               inspected.workingDirectory == project.rootDirectory,
               URL(fileURLWithPath: inspected.identity.executablePath).lastPathComponent == "node" {
                if last == inspected.identity { return inspected }
                last = inspected.identity
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProjectExecutionFailure.identityUncertain
    }

    private func waitUntilReady(_ record: ManagedProjectProcess, project: ProjectReference, url: URL) async {
        executionPhase = .checkingReadiness
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let ownedProcess, ownedProcess.processIdentifier == record.identity.pid,
                   !ownedProcess.isRunning { throw ProjectExecutionFailure.processExited }
                let inspected = try processInspector.inspect(pid: record.identity.pid)
                guard ManagedProcessSafety.isSameOwnedProjectProcess(inspected, as: record,
                    project: project, userID: getuid()) else { throw ProjectExecutionFailure.identityUncertain }
                if (try? await readinessProbe.probe(url)) == true {
                    executionPhase = .ready
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ProjectExecutionFailure.readinessTimedOut
        } catch is CancellationError {
            await performStop(record, project: project)
            if managedProcess == nil { executionPhase = .cancelled }
        } catch let failure as ProjectExecutionFailure {
            executionPhase = .failed(failure)
        } catch {
            executionPhase = .failed(.processExited)
        }
    }

    private func performStop(_ record: ManagedProjectProcess, project: ProjectReference) async {
        executionPhase = .stopping
        do {
            guard self.project?.id == project.id else { throw ProjectExecutionFailure.stopRefused }
            let inspected: InspectedProcess
            do { inspected = try processInspector.inspect(pid: record.identity.pid) }
            catch let failure as LocalReadFailure where failure.kind == .processChanged {
                try clearManagedProcess(record)
                executionPhase = .stopped
                return
            }
            guard inspected.identity == record.identity else {
                // PID reuse is stale metadata, not permission to signal the replacement.
                try clearManagedProcess(record)
                executionPhase = .failed(.identityUncertain)
                return
            }
            guard ManagedProcessSafety.isSameOwnedProjectProcess(inspected, as: record,
                project: project, userID: getuid()) else { throw ProjectExecutionFailure.stopRefused }
            // Only the exact PID captured at launch is signalled. Never use a process name,
            // port, process group or a broad repository path as the stop target.
            guard Darwin.kill(record.identity.pid, SIGTERM) == 0 else { throw ProjectExecutionFailure.stopRefused }
            for _ in 0..<30 {
                if let ownedProcess, ownedProcess.processIdentifier == record.identity.pid,
                   !ownedProcess.isRunning { break }
                if (try? processInspector.inspect(pid: record.identity.pid))?.identity != record.identity { break }
                await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
            }
            if (try? processInspector.inspect(pid: record.identity.pid))?.identity == record.identity {
                throw ProjectExecutionFailure.stopRefused
            }
            try clearManagedProcess(record)
            executionPhase = .stopped
        } catch let failure as ProjectExecutionFailure {
            executionPhase = .failed(failure)
        } catch {
            executionPhase = .failed(.stopRefused)
        }
    }

    private func clearManagedProcess(_ record: ManagedProjectProcess) throws {
        var updated = catalog
        updated.managedProcesses.removeAll { $0.projectID == record.projectID && $0.identity == record.identity }
        try persist(updated)
        transientManagedProcess = nil
        ownedProcess = nil
    }

    var managedComposeRun: ManagedComposeRun? {
        guard let project else { return nil }
        return transientComposeRun?.projectID == project.id ? transientComposeRun
            : catalog.managedComposeRuns.first { $0.projectID == project.id }
    }

    func startSelectedCompose() {
        guard !hasActiveControlTask, managedComposeRun == nil, let project else { return }
        composeTask = Task { [weak self] in
            guard let self else { return }
            await self.performComposeStart(project)
            self.composeTask = nil
        }
    }

    func cancelSelectedComposeStart() { composeTask?.cancel() }

    func stopSelectedCompose() {
        guard !hasActiveControlTask, let project, let run = managedComposeRun else { return }
        composeTask = Task { [weak self] in
            guard let self else { return }
            await self.performComposeStop(run, project: project)
            self.composeTask = nil
        }
    }

    func retryComposeReadiness() {
        guard !hasActiveControlTask, let project, let run = managedComposeRun else { return }
        composeTask = Task { [weak self] in
            guard let self else { return }
            await self.waitUntilComposeReady(run, project: project)
            self.composeTask = nil
        }
    }

    private func performComposeStart(_ project: ProjectReference) async {
        composePhase = .validating
        let revision = selectionRevision
        var baseline = Set<String>()
        var attemptedStart = false
        var configurationName: String?
        var digest: String?
        do {
            guard let profile = preferences(for: project.id).profile,
                  let name = profile.composeConfigurationName,
                  profile.trust != nil else { throw ComposeExecutionFailure.noTrustedConfiguration }
            configurationName = name
            let fresh = try await configurationReader.read(root: project.rootDirectory)
            try Task.checkCancellation()
            guard revision == selectionRevision, self.project?.id == project.id,
                  preferences(for: project.id).profile == profile else {
                throw ComposeExecutionFailure.sourceChanged
            }
            guard fresh.composeConfigurationName == name,
                  let currentDigest = fresh.composeDigest,
                  profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                    packageDigest: fresh.packageDigest,
                                    composeDigest: currentDigest) else {
                throw ComposeExecutionFailure.sourceChanged
            }
            digest = currentDigest
            if let url = readinessURL(for: project.id, compose: true),
               (try? await readinessProbe.probe(url)) == true {
                throw ComposeExecutionFailure.endpointAlreadyReady
            }
            guard let before = try await composeController.read(root: project.rootDirectory),
                  before.configurationName == name else { throw ComposeExecutionFailure.attributionUncertain }
            baseline = Set(before.containers.filter { $0.state == .running }.map(\.id))
            try Task.checkCancellation()
            guard selectionRevision == revision, self.project?.id == project.id,
                  preferences(for: project.id).profile == profile,
                  !Task.isCancelled else {
                throw ComposeExecutionFailure.sourceChanged
            }
            let latest = try await configurationReader.read(root: project.rootDirectory)
            try Task.checkCancellation()
            guard latest.composeConfigurationName == name,
                  latest.composeDigest == currentDigest else {
                throw ComposeExecutionFailure.sourceChanged
            }
            composePhase = .starting
            attemptedStart = true
            try await composeController.start(root: project.rootDirectory, configurationName: name)
            let run = try await captureStartedComposeRun(project: project, name: name,
                                                          digest: currentDigest, baseline: baseline)
            try saveComposeRun(run)
            try Task.checkCancellation()
            await waitUntilComposeReady(run, project: project)
        } catch is CancellationError {
            if attemptedStart, let name = configurationName, let digest {
                await recoverCancelledCompose(project: project, name: name, digest: digest, baseline: baseline)
            } else { composePhase = .cancelled }
        } catch let failure as ComposeExecutionFailure {
            if attemptedStart, managedComposeRun == nil, let name = configurationName, let digest {
                // Compose can partially start before its CLI reports an error. Capture only
                // label-verified newly running IDs so the user can safely stop that subset.
                if let run = try? await captureStartedComposeRun(project: project, name: name,
                                                                 digest: digest, baseline: baseline) {
                    try? saveComposeRun(run)
                }
            }
            composePhase = .failed(failure)
        } catch {
            if attemptedStart, managedComposeRun == nil, let name = configurationName, let digest,
               let run = try? await captureStartedComposeRun(project: project, name: name,
                                                              digest: digest, baseline: baseline) {
                try? saveComposeRun(run)
            }
            composePhase = .failed(attemptedStart ? .commandFailed : .sourceChanged)
        }
    }

    private func captureStartedComposeRun(project: ProjectReference, name: String,
                                           digest: String, baseline: Set<String>) async throws -> ManagedComposeRun {
        guard let after = try await composeController.read(root: project.rootDirectory),
              after.configurationName == name else { throw ComposeExecutionFailure.attributionUncertain }
        let started = after.containers.filter { $0.state == .running && !baseline.contains($0.id) }.map(\.id)
        guard !started.isEmpty, started.allSatisfy({ id in id.count == 64 && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        } }) else {
            throw ComposeExecutionFailure.noStartedContainers
        }
        return ManagedComposeRun(projectID: project.id, rootDirectory: project.rootDirectory,
                                 configurationName: name, configurationDigest: digest,
                                 containerIDs: started, launchedAt: .now)
    }

    private func saveComposeRun(_ run: ManagedComposeRun) throws {
        transientComposeRun = run
        var updated = catalog
        updated.managedComposeRuns.removeAll { $0.projectID == run.projectID }
        updated.managedComposeRuns.append(run)
        do { try persist(updated); transientComposeRun = nil }
        catch { throw ComposeExecutionFailure.persistenceFailed }
    }

    private func waitUntilComposeReady(_ run: ManagedComposeRun, project: ProjectReference) async {
        composePhase = .checkingReadiness
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard self.project?.id == project.id,
                      let status = try await composeController.read(root: project.rootDirectory),
                      status.configurationName == run.configurationName else {
                    throw ComposeExecutionFailure.attributionUncertain
                }
                let targets = run.containerIDs.compactMap { id in status.containers.first { $0.id == id } }
                guard targets.count == run.containerIDs.count else {
                    throw ComposeExecutionFailure.attributionUncertain
                }
                let running = targets.allSatisfy { $0.state == .running && $0.health != .unhealthy }
                let healthReady = targets.allSatisfy { $0.health == .healthy }
                let httpReady: Bool
                if let url = readinessURL(for: project.id, compose: true) {
                    httpReady = (try? await readinessProbe.probe(url)) == true
                } else { httpReady = false }
                if running && (healthReady || httpReady) {
                    composePhase = .ready
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw ComposeExecutionFailure.readinessTimedOut
        } catch is CancellationError {
            await Task { @MainActor in await performComposeStop(run, project: project) }.value
            if managedComposeRun == nil { composePhase = .cancelled }
        } catch let failure as ComposeExecutionFailure {
            composePhase = .failed(failure)
        } catch {
            composePhase = .failed(.attributionUncertain)
        }
    }

    private func recoverCancelledCompose(project: ProjectReference, name: String,
                                          digest: String, baseline: Set<String>) async {
        await Task { @MainActor in
            do {
                let run = try await captureStartedComposeRun(project: project, name: name,
                                                             digest: digest, baseline: baseline)
                try saveComposeRun(run)
                await performComposeStop(run, project: project)
                if managedComposeRun == nil { composePhase = .cancelled }
            } catch ComposeExecutionFailure.noStartedContainers {
                composePhase = .cancelled
            } catch {
                composePhase = .failed(.attributionUncertain)
            }
        }.value
    }

    private func performComposeStop(_ run: ManagedComposeRun, project: ProjectReference) async {
        composePhase = .stopping
        do {
            guard self.project?.id == project.id,
                  run.projectID == project.id,
                  run.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
                    == project.rootDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ComposeExecutionFailure.stopRefused
            }
            // A changed Compose file invalidates future starts, but must not strand containers
            // already launched by us. The controller rechecks every recorded ID's live labels
            // and project path immediately before signalling it.
            try await composeController.stop(root: project.rootDirectory,
                                             configurationName: run.configurationName,
                                             containerIDs: run.containerIDs)
            guard let after = try await composeController.read(root: project.rootDirectory),
                  run.containerIDs.allSatisfy({ id in
                      guard let state = after.containers.first(where: { $0.id == id })?.state else { return true }
                      return state == .exited || state == .dead
                  }) else { throw ComposeExecutionFailure.stopRefused }
            var updated = catalog
            updated.managedComposeRuns.removeAll { $0.projectID == run.projectID && $0.containerIDs == run.containerIDs }
            try persist(updated)
            transientComposeRun = nil
            composePhase = .stopped
        } catch let failure as ComposeExecutionFailure {
            composePhase = .failed(failure)
        } catch {
            composePhase = .failed(.stopRefused)
        }
    }

    func profileTrustStatus(for project: ProjectReference) -> ProfileTrustStatus {
        guard let profile = preferences(for: project.id).profile else { return .absent }
        guard profile.trust != nil else { return .draft }
        guard let reading = discovery, reading.failure == nil, let value = reading.value,
              !value.issues.contains(where: { $0.source.hasPrefix("package.json") }),
              profile.commands.isEmpty || value.packageDigest != nil,
              profile.composeConfigurationName == nil
                || (profile.composeConfigurationName == value.composeConfigurationName
                    && value.composeDigest != nil) else { return .needsScan }
        return profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                 packageDigest: value.packageDigest, composeDigest: value.composeDigest)
            ? .trusted : .sourceChanged
    }

    func trustProfile(for id: ProjectIdentifier, reviewed: ProjectProfile,
                      packageDigest: String?, composeDigest: String? = nil) async throws {
        guard let project, project.id == id, !catalogLoadBlocked,
              preferences(for: id).profile == reviewed else { throw ProfileFailure.projectChanged }
        let revision = selectionRevision
        // Re-read before recording trust so a changed repository cannot reuse an old preview.
        let fresh = try await configurationReader.read(root: project.rootDirectory)
        try Task.checkCancellation()
        guard revision == selectionRevision, self.project?.id == id,
              preferences(for: id).profile == reviewed else { throw ProfileFailure.projectChanged }
        guard !fresh.issues.contains(where: { $0.source.hasPrefix("package.json") }),
              fresh.packageDigest == packageDigest,
              reviewed.composeConfigurationName == nil
                || (fresh.composeConfigurationName == reviewed.composeConfigurationName
                    && fresh.composeDigest == composeDigest) else { throw ProfileFailure.reviewChanged }
        guard reviewed.commands.allSatisfy({ command in
            fresh.packageScripts.contains(where: { $0.name == command.scriptName })
        }) else { throw ProfileFailure.missingScript }
        guard let fingerprint = reviewed.fingerprint(projectID: id, root: project.rootDirectory,
                                                    packageDigest: fresh.packageDigest,
                                                    composeDigest: fresh.composeDigest) else {
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
                if let name = previous?.value?.composeConfigurationName, failedFiles.contains(name) {
                    value.composeConfigurationName = name
                    value.composeDigest = previous?.value?.composeDigest
                    value.composeContents = previous?.value?.composeContents
                }
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
        homebrewServices = nil
        homebrewRevision += 1
        isRefreshingHomebrewServices = false
        executionTask?.cancel()
        composeTask?.cancel()
        executionPhase = catalog.managedProcesses.contains(where: { $0.projectID == selected?.id })
            ? .recoveryRequired : .idle
        composePhase = catalog.managedComposeRuns.contains(where: { $0.projectID == selected?.id })
            ? .recoveryRequired : .idle
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
