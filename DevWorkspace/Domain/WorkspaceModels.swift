import Foundation

struct ProjectReference: Codable, Hashable, Identifiable, Sendable {
    let identity: ProjectIdentity
    let name: String

    init(
        identity: ProjectIdentity,
        name: String,
    ) {
        self.identity = identity
        self.name = name
    }

    var id: ProjectIdentifier {
        identity.identifier
    }

    var rootDirectory: URL {
        identity.canonicalRootDirectory
    }
}

enum WorkspaceLifecycle: String, Codable, Equatable, Sendable {
    case observed
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
    var upstream: String? = nil
    var isDetached = false
    var isUnborn = false
    var hasDivergence = true
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
    var readings: WorkspaceReadings? = nil

    func markedStale() -> Self {
        Self(
            project: project,
            lifecycle: lifecycle,
            git: git,
            services: services,
            observedAt: observedAt,
            freshness: .stale,
            origin: origin,
            readings: readings
        )
    }
}
