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

struct ProjectProfile: Codable, Equatable, Sendable {
    var commands: [ProfileScriptCommand] = []
    var homebrewServices: [String] = []
    var trust: ProfileTrust? = nil

    var isEmpty: Bool { commands.isEmpty && homebrewServices.isEmpty }

    func isValid() -> Bool {
        Set(commands.map(\.role)).count == commands.count
            && commands.allSatisfy { Self.validScriptName($0.scriptName) }
            && Set(homebrewServices).count == homebrewServices.count
            && homebrewServices.allSatisfy(Self.validHomebrewName)
            && (trust == nil || (trust?.fingerprint.count == 64
                && trust?.fingerprint.utf8.allSatisfy { "0123456789abcdef".utf8.contains($0) } == true))
    }

    func fingerprint(projectID: ProjectIdentifier, root: URL, packageDigest: String?) -> String? {
        guard isValid(), !isEmpty,
              commands.isEmpty || packageDigest?.count == 64 else { return nil }
        let description = FingerprintInput(projectID: projectID.rawValue,
            root: root.standardizedFileURL.resolvingSymlinksInPath().path,
            packageDigest: commands.isEmpty ? nil : packageDigest,
            commands: commands.sorted { $0.role.rawValue < $1.role.rawValue },
            homebrewServices: homebrewServices.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(description) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isTrusted(projectID: ProjectIdentifier, root: URL, packageDigest: String?) -> Bool {
        guard let trust else { return false }
        return trust.fingerprint == fingerprint(projectID: projectID, root: root, packageDigest: packageDigest)
    }

    static func validScriptName(_ value: String) -> Bool {
        validIdentifier(value, allowed: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@-")
    }

    static func validHomebrewName(_ value: String) -> Bool {
        validIdentifier(value, allowed: "abcdefghijklmnopqrstuvwxyz0123456789@+._-")
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
