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
    private(set) var javaArchiveSource: SourceReading<JavaArchiveSource>?
    private(set) var executionPhase: ProjectExecutionPhase = .idle
    private(set) var composePhase: ComposeExecutionPhase = .idle
    private(set) var workspacePhase: WorkspaceControlPhase = .idle
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
    private let javaArchiveReader: any JavaArchiveReading
    private let readinessTimeout: Duration
    private let npmExecutable: URL?
    private let composeController: any DockerComposeControlling
    private var executionTask: Task<Void, Never>?
    private var composeTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var ownedProcess: Process?
    private var transientManagedProcess: ManagedProjectProcess?
    private var transientComposeRun: ManagedComposeRun?
    private var applicationReadyCheckedAt: Date?
    private var composeReadyCheckedAt: Date?

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
        javaArchiveReader: any JavaArchiveReading = LocalJavaArchiveReader(),
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
        self.javaArchiveReader = javaArchiveReader
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
              !catalog.pendingProjectLaunches.contains(where: { $0.projectID == project.id }),
              !catalog.managedComposeRuns.contains(where: { $0.projectID == project.id }),
              transientComposeRun?.projectID != project.id,
              !catalog.pendingComposeStarts.contains(where: { $0.projectID == project.id }) else {
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
        javaArchiveSource = nil
        isRefreshingHomebrewServices = false
    }

    func refreshJavaArchiveSource() async {
        guard let project, let archive = preferences(for: project.id).profile?.javaArchive else {
            javaArchiveSource = nil
            return
        }
        let revision = selectionRevision
        let previous = javaArchiveSource
        do {
            let source = try await javaArchiveReader.read(root: project.rootDirectory, archive: archive)
            try Task.checkCancellation()
            guard revision == selectionRevision,
                  preferences(for: project.id).profile?.javaArchive == archive else { return }
            javaArchiveSource = .success(source)
        } catch is CancellationError { }
        catch {
            guard revision == selectionRevision else { return }
            javaArchiveSource = SourceReading<JavaArchiveSource>.failed(error).retainingTrustedValue(from: previous)
        }
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

    var pendingProjectLaunch: PendingProjectLaunch? {
        guard let project else { return nil }
        return catalog.pendingProjectLaunches.first { $0.projectID == project.id }
    }

    var isWorkspaceBusy: Bool { workspaceTask != nil }
    private var hasActiveControlTask: Bool {
        executionTask != nil || composeTask != nil || workspaceTask != nil
    }

    func startSelectedProject() {
        guard !hasActiveControlTask, managedProcess == nil, pendingProjectLaunch == nil,
              let project else { return }
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
                  profile.commands.contains(where: { $0.role == .start }) || profile.javaArchive != nil,
                  profile.trust != nil else { throw ProjectExecutionFailure.noTrustedStart }
            let command = profile.commands.first(where: { $0.role == .start })
            let java = profile.javaArchive
            let fresh = try await configurationReader.read(root: project.rootDirectory)
            let freshJava: JavaArchiveSource?
            if let java { freshJava = try await javaArchiveReader.read(root: project.rootDirectory, archive: java) }
            else { freshJava = nil }
            try Task.checkCancellation()
            guard selectionRevision == revision, self.project?.id == project.id,
                  preferences(for: project.id).profile == profile else {
                throw ProfileFailure.projectChanged
            }
            guard (command.map { selected in
                !fresh.issues.contains(where: { $0.source.hasPrefix("package.json") })
                    && fresh.packageScripts.contains(where: { $0.name == selected.scriptName })
            } ?? true),
                  profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                    packageDigest: fresh.packageDigest,
                                    composeDigest: fresh.composeDigest,
                                    javaDigest: freshJava?.digest) else {
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
            let latestJava: JavaArchiveSource?
            if let java { latestJava = try await javaArchiveReader.read(root: project.rootDirectory, archive: java) }
            else { latestJava = nil }
            try Task.checkCancellation()
            guard latest.packageDigest == fresh.packageDigest,
                  latestJava?.digest == freshJava?.digest,
                  (command == nil || !latest.issues.contains(where: { $0.source.hasPrefix("package.json") })) else {
                throw ProjectExecutionFailure.sourceChanged
            }
            guard let executable = java.map({ URL(fileURLWithPath: $0.executablePath) }) ?? npmExecutable,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ProjectExecutionFailure.executableUnavailable
            }
            if java != nil {
                var info = stat()
                guard lstat(executable.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                    throw ProjectExecutionFailure.executableUnavailable
                }
            }
            executionPhase = .launching
            let process = Process()
            process.executableURL = executable
            if let java {
                let archiveURL = project.rootDirectory.appendingPathComponent(java.relativePath)
                process.arguments = ["-jar", archiveURL.path]
                    + (java.springProfile.map { ["--spring.profiles.active=\($0)"] } ?? [])
                    + (java.serverPort.map { ["--server.port=\($0)"] } ?? [])
            } else if let command {
                process.arguments = ["run", command.scriptName]
            }
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
            var pending = PendingProjectLaunch(projectID: project.id, rootDirectory: project.rootDirectory,
                                               commandLabel: java.map { "java -jar \($0.relativePath)" }
                                                 ?? "npm run \(command?.scriptName ?? "")", pid: nil, createdAt: .now)
            var journal = catalog
            journal.pendingProjectLaunches.append(pending)
            do { try persist(journal) } catch { throw ProjectExecutionFailure.persistenceFailed }
            do { try process.run() }
            catch {
                _ = clearPendingProjectLaunch(project.id)
                throw ProjectExecutionFailure.launchFailed
            }
            ownedProcess = process
            pending.pid = process.processIdentifier
            journal = catalog
            journal.pendingProjectLaunches.removeAll { $0.projectID == project.id }
            journal.pendingProjectLaunches.append(pending)
            do { try persist(journal) } catch { throw ProjectExecutionFailure.persistenceFailed }
            let inspected = try await identifyLaunchedProcess(process, project: project,
                                                              expectedExecutable: java == nil ? "node" : "java")
            let record = ManagedProjectProcess(projectID: project.id, rootDirectory: project.rootDirectory,
                                               scriptName: command?.scriptName ?? "java", identity: inspected.identity,
                                               launchedAt: .now, javaArchiveRelativePath: java?.relativePath)
            transientManagedProcess = record
            var updated = catalog
            updated.managedProcesses.removeAll { $0.projectID == project.id }
            updated.managedProcesses.append(record)
            updated.pendingProjectLaunches.removeAll { $0.projectID == project.id }
            do { try persist(updated); transientManagedProcess = nil }
            catch { throw ProjectExecutionFailure.persistenceFailed }
            try Task.checkCancellation()
            await waitUntilReady(record, project: project, url: url)
        } catch is CancellationError {
            if let record = managedProcess { await performStop(record, project: project) }
            else {
                let resolved = await cleanupUnregisteredProcess(project: project)
                executionPhase = resolved ? .cancelled : .failed(.identityUncertain)
            }
        } catch let failure as ProjectExecutionFailure {
            let resolved: Bool
            if managedProcess != nil { resolved = true }
            else { resolved = await cleanupUnregisteredProcess(project: project) }
            executionPhase = .failed(resolved ? failure : .identityUncertain)
        } catch {
            let resolved: Bool
            if managedProcess != nil { resolved = true }
            else { resolved = await cleanupUnregisteredProcess(project: project) }
            executionPhase = .failed(resolved ? .sourceChanged : .identityUncertain)
        }
    }

    private func cleanupUnregisteredProcess(project: ProjectReference) async -> Bool {
        guard catalog.pendingProjectLaunches.contains(where: { $0.projectID == project.id }) else {
            return true
        }
        guard let process = ownedProcess else {
            // A journal without an in-memory Process handle may survive a crash. No PID
            // is safe to signal from that journal alone; the user must resolve it.
            return false
        }
        if !process.isRunning { ownedProcess = nil; return clearPendingProjectLaunch(project.id) }
        guard let inspected = try? processInspector.inspect(pid: process.processIdentifier),
              inspected.identity.pid == process.processIdentifier,
              inspected.identity.userID == getuid(),
              URL(fileURLWithPath: inspected.identity.executablePath).lastPathComponent
                == (pendingProjectLaunch?.commandLabel.hasPrefix("java -jar") == true ? "java" : "node"),
              inspected.workingDirectory?.standardizedFileURL.resolvingSymlinksInPath()
                == project.rootDirectory.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        // Launch failed before persistence. The live Process handle and native identity
        // still have to agree before signalling even this just-created child.
        guard Darwin.kill(inspected.identity.pid, SIGTERM) == 0 else { return false }
        for _ in 0..<30 where process.isRunning {
            await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
        guard !process.isRunning else { return false }
        ownedProcess = nil
        return clearPendingProjectLaunch(project.id)
    }

    private func clearPendingProjectLaunch(_ id: ProjectIdentifier) -> Bool {
        var updated = catalog
        updated.pendingProjectLaunches.removeAll { $0.projectID == id }
        do { try persist(updated); return true } catch { return false }
    }

    func retryPendingProjectCleanup() {
        guard !hasActiveControlTask, let project, pendingProjectLaunch != nil else { return }
        executionTask = Task { [weak self] in
            guard let self else { return }
            self.executionPhase = .stopping
            let resolved = await self.cleanupUnregisteredProcess(project: project)
            self.executionPhase = resolved ? .stopped : .failed(.identityUncertain)
            self.executionTask = nil
        }
    }

    /// The UI requires an explicit external-cleanup confirmation. A still-live recorded
    /// PID blocks forgetting, even when its identity cannot be read safely enough to stop.
    func acknowledgePendingProjectLaunch() {
        guard !hasActiveControlTask, let pending = pendingProjectLaunch else { return }
        guard ownedProcess?.isRunning != true else {
            executionPhase = .failed(.identityUncertain)
            return
        }
        if let pid = pending.pid {
            guard Darwin.kill(pid, 0) != 0, errno == ESRCH else {
                executionPhase = .failed(.identityUncertain)
                return
            }
        }
        executionPhase = clearPendingProjectLaunch(pending.projectID)
            ? .stopped : .failed(.persistenceFailed)
    }

    private func identifyLaunchedProcess(_ process: Process, project: ProjectReference,
                                         expectedExecutable: String) async throws -> InspectedProcess {
        var last: ProcessIdentity?
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard process.isRunning else { throw ProjectExecutionFailure.processExited }
            if let inspected = try? processInspector.inspect(pid: process.processIdentifier),
               inspected.identity.userID == getuid(),
               inspected.workingDirectory == project.rootDirectory,
               URL(fileURLWithPath: inspected.identity.executablePath).lastPathComponent == expectedExecutable {
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
                    applicationReadyCheckedAt = .now
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
        applicationReadyCheckedAt = nil
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
        updated.pendingProjectLaunches.removeAll { $0.projectID == record.projectID }
        try persist(updated)
        transientManagedProcess = nil
        ownedProcess = nil
    }

    var managedComposeRun: ManagedComposeRun? {
        guard let project else { return nil }
        return transientComposeRun?.projectID == project.id ? transientComposeRun
            : catalog.managedComposeRuns.first { $0.projectID == project.id }
    }

    var pendingComposeStart: PendingComposeStart? {
        guard let project else { return nil }
        return catalog.pendingComposeStarts.first { $0.projectID == project.id }
    }

    func startSelectedCompose() {
        guard !hasActiveControlTask, managedComposeRun == nil, pendingComposeStart == nil,
              let project else { return }
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
            let freshJava: JavaArchiveSource?
            if let archive = profile.javaArchive {
                freshJava = try await javaArchiveReader.read(root: project.rootDirectory, archive: archive)
            } else { freshJava = nil }
            try Task.checkCancellation()
            guard revision == selectionRevision, self.project?.id == project.id,
                  preferences(for: project.id).profile == profile else {
                throw ComposeExecutionFailure.sourceChanged
            }
            guard fresh.composeConfigurationName == name,
                  let currentDigest = fresh.composeDigest,
                  profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                    packageDigest: fresh.packageDigest,
                                    composeDigest: currentDigest, javaDigest: freshJava?.digest) else {
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
            let latestJava: JavaArchiveSource?
            if let archive = profile.javaArchive {
                latestJava = try await javaArchiveReader.read(root: project.rootDirectory, archive: archive)
            } else { latestJava = nil }
            try Task.checkCancellation()
            guard latest.composeConfigurationName == name,
                  latest.composeDigest == currentDigest,
                  latestJava?.digest == freshJava?.digest else {
                throw ComposeExecutionFailure.sourceChanged
            }
            var journal = catalog
            journal.pendingComposeStarts.append(PendingComposeStart(projectID: project.id,
                rootDirectory: project.rootDirectory, configurationName: name,
                configurationDigest: currentDigest, baselineContainerIDs: baseline.sorted(), createdAt: .now))
            do { try persist(journal) } catch { throw ComposeExecutionFailure.persistenceFailed }
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
                } else if let status = try? await composeController.read(root: project.rootDirectory),
                          status.configurationName == name,
                          status.containers.filter({ $0.state == .running && !baseline.contains($0.id) }).isEmpty {
                    _ = clearPendingComposeStart(project.id)
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
        updated.pendingComposeStarts.removeAll { $0.projectID == run.projectID }
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
                    composeReadyCheckedAt = .now
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
                composePhase = clearPendingComposeStart(project.id) ? .cancelled : .failed(.persistenceFailed)
            } catch {
                composePhase = .failed(.attributionUncertain)
            }
        }.value
    }

    private func performComposeStop(_ run: ManagedComposeRun, project: ProjectReference) async {
        composeReadyCheckedAt = nil
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
            updated.pendingComposeStarts.removeAll { $0.projectID == run.projectID }
            try persist(updated)
            transientComposeRun = nil
            composePhase = .stopped
        } catch let failure as ComposeExecutionFailure {
            composePhase = .failed(failure)
        } catch {
            composePhase = .failed(.stopRefused)
        }
    }

    private func clearPendingComposeStart(_ id: ProjectIdentifier) -> Bool {
        var updated = catalog
        updated.pendingComposeStarts.removeAll { $0.projectID == id }
        do { try persist(updated); return true } catch { return false }
    }

    func startSelectedWorkspace() {
        guard !hasActiveControlTask, let project else { return }
        workspaceTask = Task { [weak self] in
            guard let self else { return }
            await self.performWorkspaceStart(project)
            self.workspaceTask = nil
        }
    }

    func cancelSelectedWorkspaceStart() { workspaceTask?.cancel() }

    func stopSelectedWorkspace() {
        guard !hasActiveControlTask, let project else { return }
        workspaceTask = Task { [weak self] in
            guard let self else { return }
            await self.performWorkspaceStop(project)
            self.workspaceTask = nil
        }
    }

    private func performWorkspaceStart(_ selected: ProjectReference) async {
        workspacePhase = .validating
        var startedCompose = false
        var startedApplication = false
        do {
            guard project?.id == selected.id,
                  let profile = preferences(for: selected.id).profile,
                  profile.trust != nil,
                  profile.javaArchive != nil || profile.commands.contains(where: { $0.role == .start }) else {
                throw WorkspaceControlFailure.noTrustedProfile
            }
            guard pendingProjectLaunch == nil, pendingComposeStart == nil else {
                throw WorkspaceControlFailure.pendingRecovery
            }
            if !profile.homebrewServices.isEmpty {
                let previous = homebrewServices
                let statuses: [HomebrewServiceStatus]
                // A cached green status is not sufficient to authorize this launch;
                // read every declared service again even if a UI refresh is in flight.
                do { statuses = try await homebrewReader.read(names: profile.homebrewServices) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    homebrewServices = SourceReading<[HomebrewServiceStatus]>.failed(error)
                        .retainingTrustedValue(from: previous)
                    throw WorkspaceControlFailure.homebrewNotReady
                }
                try Task.checkCancellation()
                guard project?.id == selected.id,
                      preferences(for: selected.id).profile == profile else {
                    throw WorkspaceControlFailure.noTrustedProfile
                }
                homebrewServices = .success(statuses)
                guard statuses.count == profile.homebrewServices.count,
                      Set(statuses.map(\.name)) == Set(profile.homebrewServices),
                      statuses.allSatisfy({ $0.state == .running }) else {
                    throw WorkspaceControlFailure.homebrewNotReady
                }
            }
            if let name = profile.composeConfigurationName {
                workspacePhase = .startingDependencies
                if let run = managedComposeRun {
                    await waitUntilComposeReady(run, project: selected)
                    try Task.checkCancellation()
                    guard composePhase == .ready else { throw WorkspaceControlFailure.composeNotReady }
                } else if try await externalComposeIsReady(project: selected, configurationName: name) {
                    composeReadyCheckedAt = .now
                } else {
                    await performComposeStart(selected)
                    startedCompose = managedComposeRun != nil
                    try Task.checkCancellation()
                    guard composePhase == .ready else { throw WorkspaceControlFailure.composeNotReady }
                }
            }
            try Task.checkCancellation()
            workspacePhase = .startingApplication
            if let record = managedProcess {
                guard let url = readinessURL(for: selected.id, compose: false) else {
                    throw WorkspaceControlFailure.applicationNotReady
                }
                await waitUntilReady(record, project: selected, url: url)
            } else {
                await performStart(selected)
                startedApplication = managedProcess != nil
            }
            try Task.checkCancellation()
            guard executionPhase == .ready else { throw WorkspaceControlFailure.applicationNotReady }
            try Task.checkCancellation()
            workspacePhase = .ready
        } catch is CancellationError {
            // Cancellation rolls back only resources launched by this action, never
            // externally running dependencies or a process inherited from an earlier run.
            let recovered = await rollbackWorkspaceLaunch(project: selected,
                application: startedApplication, compose: startedCompose)
            workspacePhase = recovered ? .cancelled : .failed(.stopRefused)
        } catch let failure as WorkspaceControlFailure {
            let recovered = await rollbackWorkspaceLaunch(project: selected,
                application: startedApplication, compose: startedCompose)
            workspacePhase = .failed(recovered ? failure : .stopRefused)
        } catch {
            let recovered = await rollbackWorkspaceLaunch(project: selected,
                application: startedApplication, compose: startedCompose)
            workspacePhase = .failed(recovered ? .applicationNotReady : .stopRefused)
        }
    }

    private func rollbackWorkspaceLaunch(project: ProjectReference,
                                         application: Bool, compose: Bool) async -> Bool {
        // A fresh task keeps cleanup moving even when the launching task was cancelled.
        // Existing or externally owned services are never part of this rollback.
        await Task { @MainActor in
            if application, let record = managedProcess { await performStop(record, project: project) }
            if compose, let run = managedComposeRun { await performComposeStop(run, project: project) }
            return (!application || managedProcess == nil)
                && (!compose || managedComposeRun == nil)
                && pendingProjectLaunch == nil && pendingComposeStart == nil
        }.value
    }

    private func externalComposeIsReady(project: ProjectReference,
                                        configurationName: String) async throws -> Bool {
        guard let status = try await composeController.read(root: project.rootDirectory),
              status.configurationName == configurationName, !status.containers.isEmpty else { return false }
        let running = status.containers.allSatisfy { $0.state == .running && $0.health != .unhealthy }
        let healthy = status.containers.allSatisfy { $0.health == .healthy }
        let http: Bool
        if let url = readinessURL(for: project.id, compose: true) {
            http = (try? await readinessProbe.probe(url)) == true
        } else { http = false }
        return running && (healthy || http)
    }

    private func performWorkspaceStop(_ selected: ProjectReference) async {
        guard project?.id == selected.id,
              pendingProjectLaunch == nil, pendingComposeStart == nil else {
            workspacePhase = .failed(.pendingRecovery)
            return
        }
        if let record = managedProcess {
            workspacePhase = .stoppingApplication
            await performStop(record, project: selected)
            guard managedProcess == nil else { workspacePhase = .failed(.stopRefused); return }
        }
        if let run = managedComposeRun {
            workspacePhase = .stoppingDependencies
            await performComposeStop(run, project: selected)
            guard managedComposeRun == nil else { workspacePhase = .failed(.stopRefused); return }
        }
        workspacePhase = .stopped
    }

    func recoverPendingComposeStart() {
        guard !hasActiveControlTask, let project, let pending = pendingComposeStart else { return }
        composeTask = Task { [weak self] in
            guard let self else { return }
            self.composePhase = .validating
            do {
                let baseline = Set(pending.baselineContainerIDs)
                do {
                    let run = try await self.captureStartedComposeRun(project: project,
                        name: pending.configurationName, digest: pending.configurationDigest, baseline: baseline)
                    try self.saveComposeRun(run)
                    self.composePhase = .recoveryRequired
                } catch ComposeExecutionFailure.noStartedContainers {
                    guard let status = try await self.composeController.read(root: project.rootDirectory),
                          status.configurationName == pending.configurationName else {
                        throw ComposeExecutionFailure.attributionUncertain
                    }
                    self.composePhase = self.clearPendingComposeStart(project.id)
                        ? .stopped : .failed(.persistenceFailed)
                }
            } catch {
                // Keep the journal: uncertainty is never permission to forget possible containers.
                self.composePhase = .failed(.attributionUncertain)
            }
            self.composeTask = nil
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
                    && value.composeDigest != nil),
              profile.javaArchive == nil || (javaArchiveSource?.failure == nil
                    && javaArchiveSource?.value?.digest != nil) else { return .needsScan }
        return profile.isTrusted(projectID: project.id, root: project.rootDirectory,
                                 packageDigest: value.packageDigest, composeDigest: value.composeDigest,
                                 javaDigest: javaArchiveSource?.value?.digest)
            ? .trusted : .sourceChanged
    }

    func trustProfile(for id: ProjectIdentifier, reviewed: ProjectProfile,
                      packageDigest: String?, composeDigest: String? = nil,
                      javaDigest: String? = nil) async throws {
        guard let project, project.id == id, !catalogLoadBlocked,
              preferences(for: id).profile == reviewed else { throw ProfileFailure.projectChanged }
        let revision = selectionRevision
        // Re-read before recording trust so a changed repository cannot reuse an old preview.
        let fresh = try await configurationReader.read(root: project.rootDirectory)
        let freshJava: JavaArchiveSource?
        if let archive = reviewed.javaArchive {
            freshJava = try await javaArchiveReader.read(root: project.rootDirectory, archive: archive)
        } else { freshJava = nil }
        try Task.checkCancellation()
        guard revision == selectionRevision, self.project?.id == id,
              preferences(for: id).profile == reviewed else { throw ProfileFailure.projectChanged }
        guard !fresh.issues.contains(where: { $0.source.hasPrefix("package.json") }),
              fresh.packageDigest == packageDigest,
              freshJava?.digest == javaDigest,
              reviewed.composeConfigurationName == nil
                || (fresh.composeConfigurationName == reviewed.composeConfigurationName
                    && fresh.composeDigest == composeDigest) else { throw ProfileFailure.reviewChanged }
        guard reviewed.commands.allSatisfy({ command in
            fresh.packageScripts.contains(where: { $0.name == command.scriptName })
        }) else { throw ProfileFailure.missingScript }
        guard let fingerprint = reviewed.fingerprint(projectID: id, root: project.rootDirectory,
                                                    packageDigest: fresh.packageDigest,
                                                    composeDigest: fresh.composeDigest,
                                                    javaDigest: freshJava?.digest) else {
            throw ProfileFailure.invalidProfile
        }
        var preferences = preferences(for: id)
        var trusted = reviewed
        trusted.trust = ProfileTrust(fingerprint: fingerprint, acceptedAt: .now)
        preferences.profile = trusted
        try savePreferences(preferences)
        if let freshJava { javaArchiveSource = .success(freshJava) }
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
        javaArchiveSource = nil
        applicationReadyCheckedAt = nil
        composeReadyCheckedAt = nil
        homebrewRevision += 1
        isRefreshingHomebrewServices = false
        executionTask?.cancel()
        composeTask?.cancel()
        executionPhase = catalog.managedProcesses.contains(where: { $0.projectID == selected?.id })
            || catalog.pendingProjectLaunches.contains(where: { $0.projectID == selected?.id })
            ? .recoveryRequired : .idle
        composePhase = catalog.managedComposeRuns.contains(where: { $0.projectID == selected?.id })
            || catalog.pendingComposeStarts.contains(where: { $0.projectID == selected?.id })
            ? .recoveryRequired : .idle
        workspacePhase = executionPhase == .recoveryRequired || composePhase == .recoveryRequired
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

    var operationalLifecycle: WorkspaceLifecycle {
        guard let project,
              let profile = preferences(for: project.id).profile,
              profile.javaArchive != nil || profile.commands.contains(where: { $0.role == .start }) else {
            return .observed
        }
        if pendingProjectLaunch != nil || pendingComposeStart != nil { return .degraded }
        switch workspacePhase {
        case .validating, .startingDependencies, .startingApplication,
             .stoppingApplication, .stoppingDependencies: return .starting
        case .failed: return .failed
        case .recoveryRequired: return .degraded
        case .idle, .ready, .stopped, .cancelled: break
        }
        if case .failed = executionPhase { return .degraded }
        if case .failed = composePhase { return .degraded }
        // A previously successful HTTP response expires; refresh must verify it again.
        // Background polling is at most five minutes, so six minutes allows one cycle.
        let applicationReady = managedProcess != nil && executionPhase == .ready
            && ownedProcess?.isRunning != false
            && applicationReadyCheckedAt.map { Date.now.timeIntervalSince($0) < 360 } == true
        let homebrewReady = profile.homebrewServices.isEmpty
            || (homebrewServices?.failure == nil
                && homebrewServices?.value?.count == profile.homebrewServices.count
                && Set(homebrewServices?.value?.map(\.name) ?? []) == Set(profile.homebrewServices)
                && homebrewServices?.value?.allSatisfy({ $0.state == .running }) == true)
        let composeReady = profile.composeConfigurationName == nil
            || ((composePhase == .ready || workspacePhase == .ready)
                && composeReadyCheckedAt.map { Date.now.timeIntervalSince($0) < 360 } == true)
        if applicationReady && homebrewReady && composeReady { return .ready }
        if managedProcess != nil || managedComposeRun != nil { return .degraded }
        return .stopped
    }

    var readyPrimaryURL: URL? {
        guard operationalLifecycle == .ready, let project else { return nil }
        return readinessURL(for: project.id, compose: false)
    }

    var presentationSnapshot: WorkspaceSnapshot? { currentSnapshot.map(present) }

    var presentationState: State {
        switch state {
        case .idle, .failed: state
        case let .refreshing(previous): .refreshing(previous: previous.map(present))
        case let .ready(snapshot): .ready(present(snapshot))
        case let .degraded(snapshot, message): .degraded(snapshot: present(snapshot), message: message)
        }
    }

    private func present(_ snapshot: WorkspaceSnapshot) -> WorkspaceSnapshot {
        guard snapshot.project.id == project?.id, snapshot.origin == .local else { return snapshot }
        var services: [ServiceSummary] = []
        if let profile = preferences(for: snapshot.project.id).profile {
            for name in profile.homebrewServices {
                let running = homebrewServices?.failure == nil
                    && homebrewServices?.value?.first(where: { $0.name == name })?.state == .running
                services.append(ServiceSummary(id: "homebrew:\(name)", name: name, kind: .dependency,
                                               health: running ? .healthy : .unknown, port: nil))
            }
            if profile.javaArchive != nil || profile.commands.contains(where: { $0.role == .start }) {
                let port = readinessURL(for: snapshot.project.id, compose: false)
                    .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.port }
                    .flatMap(UInt16.init)
                services.append(ServiceSummary(id: "application", name: snapshot.project.name,
                    kind: .application, health: applicationReadyCheckedAt.map { Date.now.timeIntervalSince($0) < 360 } == true
                        && executionPhase == .ready && ownedProcess?.isRunning != false ? .healthy
                        : managedProcess == nil ? .stopped : .unknown, port: port))
            }
        }
        if snapshot.readings?.compose?.failure == nil {
            for container in snapshot.readings?.compose?.value?.containers ?? [] {
                let health: ServiceHealth = switch (container.state, container.health) {
                case (.running, .healthy): .healthy
                case (.running, .unhealthy): .unhealthy
                case (.running, .starting): .starting
                case (.running, nil): .unknown
                default: .stopped
                }
                services.append(ServiceSummary(id: "compose:\(container.id)", name: container.serviceName,
                    kind: .container, health: health, port: container.ports.first?.published))
            }
        }
        return WorkspaceSnapshot(project: snapshot.project, lifecycle: operationalLifecycle,
            git: snapshot.git, services: services, observedAt: snapshot.observedAt,
            freshness: snapshot.freshness, origin: snapshot.origin, readings: snapshot.readings)
    }

    private func verifyOperationalReadiness(project: ProjectReference, revision: Int) async {
        if let record = managedProcess, executionPhase == .ready,
           let url = readinessURL(for: project.id, compose: false) {
            let identityMatches = (try? processInspector.inspect(pid: record.identity.pid)).map {
                ManagedProcessSafety.isSameOwnedProjectProcess($0, as: record,
                    project: project, userID: getuid())
            } == true
            let responds: Bool
            if identityMatches { responds = (try? await readinessProbe.probe(url)) == true }
            else { responds = false }
            guard revision == selectionRevision else { return }
            applicationReadyCheckedAt = responds ? .now : nil
        }
        if let name = preferences(for: project.id).profile?.composeConfigurationName,
           composePhase == .ready || workspacePhase == .ready {
            let status = try? await composeController.read(root: project.rootDirectory)
            guard revision == selectionRevision else { return }
            let containers: [ComposeContainer]?
            if let status, status.configurationName == name, let run = managedComposeRun {
                let matches = run.containerIDs.compactMap { id in status.containers.first { $0.id == id } }
                containers = matches.count == run.containerIDs.count ? matches : nil
            } else if let status, status.configurationName == name {
                containers = status.containers
            } else { containers = nil }
            if let containers {
                let running = !containers.isEmpty && containers.allSatisfy {
                    $0.state == .running && $0.health != .unhealthy
                }
                let healthy = containers.allSatisfy { $0.health == .healthy }
                let responds: Bool
                if let url = readinessURL(for: project.id, compose: true) {
                    responds = (try? await readinessProbe.probe(url)) == true
                } else { responds = false }
                guard revision == selectionRevision else { return }
                composeReadyCheckedAt = running && (healthy || responds) ? .now : nil
            } else { composeReadyCheckedAt = nil }
        }
        if !((preferences(for: project.id).profile?.homebrewServices) ?? []).isEmpty {
            await refreshHomebrewServices()
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
                await verifyOperationalReadiness(project: project, revision: revision)
                guard revision == selectionRevision else { return }
                state = merged.hasFailure ? .degraded(snapshot: snapshot, message: .partialRead) : .ready(snapshot)
                return
            }
            // 数据源可以返回历史缓存；即使调用成功，也不能把明确标记为 stale 的快照
            // 提升为 Ready，否则会破坏“旧数据不得伪装为实时状态”的可信边界。
            await verifyOperationalReadiness(project: project, revision: revision)
            guard revision == selectionRevision else { return }
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
