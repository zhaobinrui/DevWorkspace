import Foundation

struct ObservedWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
    var gitReader: any GitStatusReading = LocalGitStatusReader()
    var portScanner: any LocalPortScanning = LocalPortScanner()

    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        async let git = readGit(project)
        async let ports = readPorts(project)
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

    private func readPorts(_ project: ProjectReference) async throws -> SourceReading<[ListeningProcess]> {
        do {
            _ = try LocalGitClient.validateDirectory(project.rootDirectory)
            return .success(try await portScanner.scan())
        } catch is CancellationError { throw CancellationError() }
        catch { return .failed(error) }
    }
}
