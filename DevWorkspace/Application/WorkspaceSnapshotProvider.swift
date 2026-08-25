import Foundation

protocol WorkspaceSnapshotProviding: Sendable {
    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot
}

enum WorkspaceProviderError: LocalizedError, Sendable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message
        }
    }
}
