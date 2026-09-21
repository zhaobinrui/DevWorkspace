import Foundation

enum LocalFailureKind: String, Codable, Sendable {
    case permissionDenied, timedOut, unavailable, invalidOutput, outputLimit
    case invalidDirectory, identityConflict, processChanged, corruptStorage, unsupportedVersion
}

struct LocalReadFailure: Error, Codable, Equatable, Sendable {
    let kind: LocalFailureKind

    static func classify(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        let nsError = error as NSError
        if (nsError.domain == NSPOSIXErrorDomain && [1, 13].contains(nsError.code))
            || (nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code)) {
            return Self(kind: .permissionDenied)
        }
        return Self(kind: .unavailable)
    }
}

/// A failed attempt never advances the timestamp of the last successful value.
struct SourceReading<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value?
    var checkedAt: Date?
    let attemptedAt: Date
    let failure: LocalReadFailure?

    static func success(_ value: Value?, at date: Date = .now) -> Self {
        Self(value: value, checkedAt: date, attemptedAt: date, failure: nil)
    }

    static func failed(_ error: any Error, at date: Date = .now) -> Self {
        Self(value: nil, checkedAt: nil, attemptedAt: date, failure: .classify(error))
    }

    func retainingTrustedValue(from previous: Self?) -> Self {
        guard failure != nil, let previous else { return self }
        var result = self
        result.value = previous.value
        result.checkedAt = previous.checkedAt
        return result
    }
}

struct WorkspaceReadings: Codable, Equatable, Sendable {
    var git: SourceReading<GitSummary>
    var ports: SourceReading<[ListeningProcess]>

    var hasFailure: Bool { git.failure != nil || ports.failure != nil }

    func retainingTrustedValues(from previous: Self?) -> Self {
        Self(
            git: git.retainingTrustedValue(from: previous?.git),
            ports: ports.retainingTrustedValue(from: previous?.ports)
        )
    }
}

enum SocketTransport: String, Codable, Sendable { case tcp = "TCP", udp = "UDP" }

struct ListeningSocket: Codable, Hashable, Sendable {
    let transport: SocketTransport
    let address: String
    let port: UInt16
}

struct ProcessIdentity: Codable, Hashable, Sendable {
    let pid: Int32
    let userID: UInt32
    let executablePath: String
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

struct ListeningProcess: Codable, Equatable, Identifiable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let userName: String
    let workingDirectory: URL?
    let directoryFailure: LocalReadFailure?
    let sockets: [ListeningSocket]

    var id: ProcessIdentity { identity }

    var runtime: String {
        let executable = URL(fileURLWithPath: identity.executablePath).lastPathComponent.lowercased()
        if executable.hasPrefix("node") || ["bun", "deno"].contains(executable) { return "JavaScript" }
        if executable == "java" { return "Java" }
        if executable.hasPrefix("python") { return "Python" }
        if executable.hasPrefix("postgres") { return "PostgreSQL" }
        if executable.hasPrefix("redis") { return "Redis" }
        if executable.hasPrefix("mysqld") { return "MySQL" }
        // Native binaries (including Rust) cannot be reliably identified by their names alone.
        return ""
    }
}

struct ProcessProjectBinding: Codable, Equatable, Sendable {
    let process: ProcessIdentity
    /// nil is an explicit exclusion, not an instruction to guess again.
    let projectID: ProjectIdentifier?
}

enum ProcessAttribution: Equatable, Sendable {
    case directory(ProjectIdentifier)
    case manual(ProjectIdentifier)
    case excluded
    case unassigned

    var projectID: ProjectIdentifier? {
        switch self {
        case let .directory(id), let .manual(id): id
        case .excluded, .unassigned: nil
        }
    }
}

enum ProjectAttributionResolver {
    static func resolve(
        _ process: ListeningProcess,
        projects: [ProjectReference],
        bindings: [ProcessProjectBinding]
    ) -> ProcessAttribution {
        // Bindings include start time, executable and owner, so a reused PID never inherits consent.
        if let binding = bindings.first(where: { $0.process == process.identity }) {
            if let id = binding.projectID, projects.contains(where: { $0.id == id }) { return .manual(id) }
            return .excluded
        }
        guard let directory = process.workingDirectory?.standardizedFileURL.resolvingSymlinksInPath() else {
            return .unassigned
        }
        let candidates = projects.filter {
            let root = $0.rootDirectory.path
            return directory.path == root || directory.path.hasPrefix(root == "/" ? "/" : root + "/")
        }.sorted { $0.rootDirectory.path.count > $1.rootDirectory.path.count }
        // A nested registered repository owns its own processes; never merge by a raw path prefix.
        guard let project = candidates.first else { return .unassigned }
        return .directory(project.id)
    }
}

struct ProjectCatalog: Codable, Equatable, Sendable {
    var version = 1
    var projects: [ProjectReference] = []
    var selectedID: ProjectIdentifier? = nil
    var bindings: [ProcessProjectBinding] = []
}
