import Foundation

enum ComposeContainerState: String, Codable, Sendable {
    case running, exited, created, paused, restarting, removing, dead
}

enum ComposeContainerHealth: String, Codable, Sendable {
    case healthy, unhealthy, starting
}

struct ComposePublishedPort: Codable, Equatable, Hashable, Sendable {
    let address: String
    let target: UInt16
    let published: UInt16
    let transport: String
}

struct ComposeContainer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectName: String
    let serviceName: String
    let state: ComposeContainerState
    let health: ComposeContainerHealth?
    let ports: [ComposePublishedPort]

    var isUnhealthy: Bool { state == .running && health == .unhealthy }
}

/// The configuration file and Compose project name are attribution evidence, not a container-name guess.
struct ComposeProjectStatus: Codable, Equatable, Sendable {
    let configurationName: String
    let projectName: String?
    let containers: [ComposeContainer]
}
