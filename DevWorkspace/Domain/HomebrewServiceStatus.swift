import Foundation

enum HomebrewServiceState: String, Codable, Sendable {
    case running, stopped, notRegistered
}

struct HomebrewServiceStatus: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let state: HomebrewServiceState
    let pid: Int32?

    var id: String { name }
}

protocol HomebrewServiceStatusReading: Sendable {
    func read(names: [String]) async throws -> [HomebrewServiceStatus]
}
