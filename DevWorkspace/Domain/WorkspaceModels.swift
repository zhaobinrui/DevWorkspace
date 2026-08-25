import Foundation

struct ProjectReference: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let rootDirectory: URL

    init(
        id: UUID = UUID(),
        name: String,
        rootDirectory: URL
    ) {
        self.id = id
        self.name = name
        self.rootDirectory = rootDirectory
    }
}

enum WorkspaceLifecycle: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case ready
    case degraded
    case failed
}

struct GitSummary: Codable, Equatable, Sendable {
    let branch: String
    let changedFileCount: Int
    let commitsAhead: Int
    let commitsBehind: Int
}

enum ServiceKind: String, Codable, Equatable, Sendable {
    case application
    case dependency
    case container
}

enum ServiceHealth: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case healthy
    case unhealthy
    case unknown
}

struct ServiceSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: ServiceKind
    let health: ServiceHealth
    let port: UInt16?
}

enum SnapshotFreshness: String, Codable, Equatable, Sendable {
    case current
    case stale
}

enum SnapshotOrigin: String, Codable, Equatable, Sendable {
    case local
    case preview
}

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    let project: ProjectReference
    let lifecycle: WorkspaceLifecycle
    let git: GitSummary?
    let services: [ServiceSummary]
    let observedAt: Date
    let freshness: SnapshotFreshness
    let origin: SnapshotOrigin

    func markedStale() -> Self {
        Self(
            project: project,
            lifecycle: lifecycle,
            git: git,
            services: services,
            observedAt: observedAt,
            freshness: .stale,
            origin: origin
        )
    }
}
