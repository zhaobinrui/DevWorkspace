import CryptoKit
import Foundation

enum ProfileCommandRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case start, stop, test
    var id: String { rawValue }
}

struct ProfileScriptCommand: Codable, Equatable, Identifiable, Sendable {
    let role: ProfileCommandRole
    let scriptName: String
    var id: String { role.rawValue }
}

struct ProfileTrust: Codable, Equatable, Sendable {
    let fingerprint: String
    let acceptedAt: Date
}

/// A deliberately narrow native Java launch: no shell, arbitrary JVM flags,
/// environment secrets or build hooks are imported from an untrusted checkout.
struct ProfileJavaArchive: Codable, Equatable, Sendable {
    var relativePath: String
    var executablePath: String
    var springProfile: String? = nil
    var serverPort: UInt16? = nil

    var isValid: Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && relativePath.utf8.count <= 512
            && relativePath.hasSuffix(".jar")
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }
            && executablePath.hasPrefix("/") && executablePath.utf8.count <= 1_024
            && URL(fileURLWithPath: executablePath).lastPathComponent == "java"
            && (springProfile == nil || (!springProfile!.isEmpty && springProfile!.utf8.count <= 80
                && springProfile!.utf8.allSatisfy { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8.contains($0) }))
            && (serverPort == nil || serverPort! > 0)
    }
}

struct ProjectProfile: Codable, Equatable, Sendable {
    var commands: [ProfileScriptCommand] = []
    var homebrewServices: [String] = []
    var composeConfigurationName: String? = nil
    var processReadinessURL: URL? = nil
    var composeReadinessURL: URL? = nil
    var javaArchive: ProfileJavaArchive? = nil
    var trust: ProfileTrust? = nil

    var isEmpty: Bool { commands.isEmpty && homebrewServices.isEmpty && composeConfigurationName == nil && javaArchive == nil }

    func isValid() -> Bool {
        Set(commands.map(\.role)).count == commands.count
            && commands.allSatisfy { Self.validScriptName($0.scriptName) }
            && Set(homebrewServices).count == homebrewServices.count
            && homebrewServices.allSatisfy(Self.validHomebrewName)
            && (composeConfigurationName == nil || Self.validComposeName(composeConfigurationName!))
            && (processReadinessURL == nil || ((commands.contains(where: { $0.role == .start }) || javaArchive != nil)
                && Self.validReadinessURL(processReadinessURL!)))
            && (composeReadinessURL == nil || (composeConfigurationName != nil
                && Self.validReadinessURL(composeReadinessURL!)))
            && (javaArchive == nil || (javaArchive!.isValid
                && !commands.contains(where: { $0.role == .start })))
            && (trust == nil || (trust?.fingerprint.count == 64
                && trust?.fingerprint.utf8.allSatisfy { "0123456789abcdef".utf8.contains($0) } == true))
    }

    func fingerprint(projectID: ProjectIdentifier, root: URL, packageDigest: String?,
                     composeDigest: String? = nil, javaDigest: String? = nil) -> String? {
        guard isValid(), !isEmpty,
              commands.isEmpty || packageDigest?.count == 64,
              composeConfigurationName == nil || composeDigest?.count == 64,
              javaArchive == nil || javaDigest?.count == 64 else { return nil }
        let description = FingerprintInput(projectID: projectID.rawValue,
            root: root.standardizedFileURL.resolvingSymlinksInPath().path,
            packageDigest: commands.isEmpty ? nil : packageDigest,
            commands: commands.sorted { $0.role.rawValue < $1.role.rawValue },
            homebrewServices: homebrewServices.sorted(),
            composeConfigurationName: composeConfigurationName,
            composeDigest: composeConfigurationName == nil ? nil : composeDigest,
            processReadinessURL: processReadinessURL?.absoluteString,
            composeReadinessURL: composeReadinessURL?.absoluteString,
            javaArchive: javaArchive, javaDigest: javaArchive == nil ? nil : javaDigest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(description) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isTrusted(projectID: ProjectIdentifier, root: URL, packageDigest: String?,
                   composeDigest: String? = nil, javaDigest: String? = nil) -> Bool {
        guard let trust else { return false }
        return trust.fingerprint == fingerprint(projectID: projectID, root: root,
                                                packageDigest: packageDigest, composeDigest: composeDigest,
                                                javaDigest: javaDigest)
    }

    static func validScriptName(_ value: String) -> Bool {
        validIdentifier(value, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@-")
    }

    static func validHomebrewName(_ value: String) -> Bool {
        validIdentifier(value, allowed: "abcdefghijklmnopqrstuvwxyz0123456789@+._-")
    }

    static func validComposeName(_ value: String) -> Bool {
        ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"].contains(value)
    }

    static func validReadinessURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              let port = parts.port, (1...65_535).contains(port),
              let host = parts.host?.lowercased() else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains(host)
    }

    private static func validIdentifier(_ value: String, allowed: String) -> Bool {
        guard let first = value.utf8.first,
              (48...57).contains(first) || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.count <= 80 && value.utf8.allSatisfy { allowed.utf8.contains($0) }
    }

    private struct FingerprintInput: Encodable {
        let projectID: String
        let root: String
        let packageDigest: String?
        let commands: [ProfileScriptCommand]
        let homebrewServices: [String]
        let composeConfigurationName: String?
        let composeDigest: String?
        let processReadinessURL: String?
        let composeReadinessURL: String?
        let javaArchive: ProfileJavaArchive?
        let javaDigest: String?
    }
}

struct DiscoveredPackageScript: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let body: String
    var id: String { name }
}

enum ProfileTrustStatus: Equatable, Sendable {
    case absent, draft, needsScan, sourceChanged, trusted
}

enum ProfileFailure: Error, Sendable {
    case invalidProfile, reviewChanged, missingScript, projectChanged
}
