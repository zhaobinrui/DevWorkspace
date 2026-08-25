import Foundation

protocol GitStatusReading: Sendable {
    func status(for project: ProjectReference) async throws -> GitSummary?
}

protocol PortScanning: Sendable {
    func applicationServices(for project: ProjectReference) async throws -> [ServiceSummary]
}

protocol DependencyStatusReading: Sendable {
    func dependencies(for project: ProjectReference) async throws -> [ServiceSummary]
}

struct LocalWorkspaceSnapshotProvider: WorkspaceSnapshotProviding, Sendable {
    private let gitReader: any GitStatusReading
    private let portScanner: any PortScanning
    private let dependencyReader: any DependencyStatusReading

    init(
        gitReader: any GitStatusReading,
        portScanner: any PortScanning,
        dependencyReader: any DependencyStatusReading
    ) {
        self.gitReader = gitReader
        self.portScanner = portScanner
        self.dependencyReader = dependencyReader
    }

    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        async let git = gitReader.status(for: project)
        async let applicationServices = portScanner.applicationServices(for: project)
        async let dependencies = dependencyReader.dependencies(for: project)

        return try await WorkspaceSnapshot(
            project: project,
            lifecycle: .stopped,
            git: git,
            services: applicationServices + dependencies,
            observedAt: .now,
            freshness: .current,
            origin: .local
        )
    }
}

struct PreviewWorkspaceSnapshotProvider: WorkspaceSnapshotProviding, Sendable {
    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            project: project,
            lifecycle: .ready,
            git: GitSummary(
                branch: "main",
                changedFileCount: 2,
                commitsAhead: 1,
                commitsBehind: 0
            ),
            services: [
                ServiceSummary(
                    id: "api",
                    name: "API",
                    kind: .application,
                    health: .healthy,
                    port: 7201
                ),
                ServiceSummary(
                    id: "postgresql",
                    name: "PostgreSQL",
                    kind: .dependency,
                    health: .healthy,
                    port: 5432
                ),
                ServiceSummary(
                    id: "redis",
                    name: "Redis",
                    kind: .dependency,
                    health: .stopped,
                    port: 6379
                ),
            ],
            observedAt: .now,
            freshness: .current,
            origin: .preview
        )
    }
}
