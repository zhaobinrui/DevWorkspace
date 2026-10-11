import Foundation

struct ManagedProjectProcess: Codable, Equatable, Sendable {
    let projectID: ProjectIdentifier
    let rootDirectory: URL
    let scriptName: String
    let identity: ProcessIdentity
    let launchedAt: Date
    var javaArchiveRelativePath: String? = nil
}

/// Written before spawning so a crash or failed identity read never makes a
/// possibly running child disappear from the project's control surface.
struct PendingProjectLaunch: Codable, Equatable, Sendable {
    let projectID: ProjectIdentifier
    let rootDirectory: URL
    let commandLabel: String
    var pid: Int32?
    let createdAt: Date
}

struct PendingComposeStart: Codable, Equatable, Sendable {
    let projectID: ProjectIdentifier
    let rootDirectory: URL
    let configurationName: String
    let configurationDigest: String
    let baselineContainerIDs: [String]
    let createdAt: Date
}

enum ProjectExecutionPhase: Equatable, Sendable {
    case idle, validating, launching, checkingReadiness, ready, stopping, stopped, cancelled
    case recoveryRequired
    case failed(ProjectExecutionFailure)
}

enum ProjectExecutionFailure: String, Error, Sendable {
    case noTrustedStart, sourceChanged, missingReadinessURL, executableUnavailable
    case launchFailed, identityUncertain, processExited, readinessTimedOut
    case endpointAlreadyReady, stopRefused, persistenceFailed
}

enum ManagedProcessSafety {
    static func isSameOwnedProjectProcess(_ actual: InspectedProcess,
                                          as recorded: ManagedProjectProcess,
                                          project: ProjectReference, userID: UInt32) -> Bool {
        guard actual.identity == recorded.identity,
              actual.identity.userID == userID,
              recorded.projectID == project.id,
              recorded.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
                == project.rootDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              let directory = actual.workingDirectory?.standardizedFileURL.resolvingSymlinksInPath() else {
            return false
        }
        // Require exact cwd rather than a broad path prefix: a sibling project in the
        // same repository must never become a stop target after a PID is recycled.
        return directory == project.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct ManagedComposeRun: Codable, Equatable, Sendable {
    let projectID: ProjectIdentifier
    let rootDirectory: URL
    let configurationName: String
    let configurationDigest: String
    let containerIDs: [String]
    let launchedAt: Date
}

enum ComposeExecutionFailure: String, Error, Sendable {
    case noTrustedConfiguration, sourceChanged, commandFailed, attributionUncertain
    case noStartedContainers, readinessTimedOut, stopRefused, persistenceFailed, endpointAlreadyReady
}

enum ComposeExecutionPhase: Equatable, Sendable {
    case idle, validating, starting, checkingReadiness, ready, stopping, stopped, cancelled
    case recoveryRequired
    case failed(ComposeExecutionFailure)
}

enum WorkspaceControlFailure: String, Error, Sendable {
    case noTrustedProfile, homebrewNotReady, composeNotReady, applicationNotReady
    case pendingRecovery, stopRefused
}

enum WorkspaceControlPhase: Equatable, Sendable {
    case idle, validating, startingDependencies, startingApplication, ready
    case stoppingApplication, stoppingDependencies, stopped, cancelled, recoveryRequired
    case failed(WorkspaceControlFailure)
}
