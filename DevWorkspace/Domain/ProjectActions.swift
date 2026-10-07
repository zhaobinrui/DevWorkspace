import Foundation

struct ProjectEditor: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let applicationURL: URL
    let name: String
}

struct ProjectLink: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var url: URL
}

struct ProjectPreferences: Codable, Equatable, Sendable {
    let projectID: ProjectIdentifier
    var editor: ProjectEditor?
    var links: [ProjectLink] = []
    var profile: ProjectProfile? = nil
}

enum ProjectURLPolicy {
    static func validated(_ value: String) -> URL? {
        // Configuration is untrusted. Credentials, queries and fragments can carry secrets;
        // keep saved launch addresses deliberately narrower than arbitrary browser URLs.
        guard value.count <= 2048, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains("${"), !value.contains("{{"),
              let parts = URLComponents(string: value),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }
}

struct DiscoveredProjectLink: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let url: URL
    let source: String
    var id: String { source + url.absoluteString }
}

struct ProjectDiscovery: Codable, Equatable, Sendable {
    var links: [DiscoveredProjectLink] = []
    var dockerFiles: [String] = []
    var packageScripts: [DiscoveredPackageScript] = []
    var packageDigest: String? = nil
    var issues: [ConfigurationIssue] = []
}

struct ConfigurationIssue: Codable, Equatable, Sendable {
    let source: String
    let failure: LocalReadFailure
}

protocol ProjectConfigurationReading: Sendable {
    func read(root: URL) async throws -> ProjectDiscovery
}

enum ProjectActionFailure: String, Error {
    case missingApplication, invalidURL, openFailed, clipboardFailed
}

/// Finder and Terminal are folder actions, so using them never replaces a project's editor choice.
enum CommonProjectEditor: String, CaseIterable, Identifiable, Sendable {
    case visualStudioCode, intellijIDEA
    var id: String { rawValue }
    var name: String { self == .visualStudioCode ? "VS Code" : "IntelliJ IDEA" }
    var symbol: String { self == .visualStudioCode ? "chevron.left.forwardslash.chevron.right" : "curlybraces" }
    var bundleIdentifiers: [String] {
        switch self {
        case .visualStudioCode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .intellijIDEA: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.intellij-EAP"]
        }
    }
}
