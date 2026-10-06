import Foundation

struct ObservedWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
    var gitReader: any GitStatusReading = LocalGitStatusReader()
    let processReader: SharedUserProcessReader

    init(gitReader: any GitStatusReading = LocalGitStatusReader(), portScanner: any LocalPortScanning = LocalPortScanner()) {
        self.gitReader = gitReader
        self.processReader = SharedUserProcessReader(scanner: portScanner)
    }

    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        try await snapshot(for: project, refreshProcesses: false)
    }

    func snapshot(for project: ProjectReference, refreshProcesses: Bool) async throws -> WorkspaceSnapshot {
        async let git = readGit(project)
        async let ports = processReader.read(force: refreshProcesses)
        let readings = try await WorkspaceReadings(git: git, ports: ports)
        try Task.checkCancellation()
        // Listening is not proof of application health; this phase only claims that local status was observed.
        return WorkspaceSnapshot(project: project, lifecycle: .observed, git: readings.git.value,
                                 services: [], observedAt: .now, freshness: .current, origin: .local, readings: readings)
    }

    private func readGit(_ project: ProjectReference) async throws -> SourceReading<GitSummary> {
        do { return .success(try await gitReader.status(for: project)) }
        catch is CancellationError { throw CancellationError() }
        catch { return .failed(error) }
    }

    func userProcesses(force: Bool) async throws -> SourceReading<[ListeningProcess]>? {
        // User-wide process observation must keep working even when a selected repository disappears.
        try await processReader.read(force: force)
    }
}
