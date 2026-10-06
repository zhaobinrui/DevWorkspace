import Foundation

protocol WorkspaceSnapshotProviding: Sendable {
    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot
    func snapshot(for project: ProjectReference, refreshProcesses: Bool) async throws -> WorkspaceSnapshot
    func userProcesses(force: Bool) async throws -> SourceReading<[ListeningProcess]>?
}

extension WorkspaceSnapshotProviding {
    func snapshot(for project: ProjectReference, refreshProcesses: Bool) async throws -> WorkspaceSnapshot {
        try await snapshot(for: project)
    }
    func userProcesses(force: Bool) async throws -> SourceReading<[ListeningProcess]>? { nil }
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
