import CryptoKit
import Foundation

struct LocalProjectIdentityResolver: ProjectIdentityResolving, Sendable {
    func resolve(
        rootDirectory: URL,
        declaredMetadataID: UUID? = nil
    ) throws -> ProjectIdentity {
        guard rootDirectory.isFileURL else {
            throw ProjectIdentityError.nonFileURL
        }

        let canonicalRoot = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = canonicalRoot.path.precomposedStringWithCanonicalMapping
        guard !canonicalPath.isEmpty else {
            throw ProjectIdentityError.missingRootPath
        }

        let seed: String
        let source: ProjectIdentitySource

        if let declaredMetadataID {
            seed = "metadata:\(declaredMetadataID.uuidString.lowercased())"
            source = .declaredMetadata
        } else if let resourceIdentifier = fileResourceIdentifier(for: canonicalRoot) {
            seed = "filesystem:\(resourceIdentifier)"
            source = .fileSystemResource
        } else {
            seed = "canonical-root:\(canonicalPath)"
            source = .canonicalRoot
        }

        let digest = SHA256.hash(
            data: Data("devspace.project.identity/v1\0\(seed)".utf8)
        )
        let hexadecimalDigest = digest.map { String(format: "%02x", $0) }.joined()
        let rawIdentifier = ProjectIdentifier.prefix + hexadecimalDigest

        guard let identifier = ProjectIdentifier(rawValue: rawIdentifier) else {
            preconditionFailure("SHA-256 must produce a valid DevSpace project identifier")
        }

        return ProjectIdentity(
            identifier: identifier,
            source: source,
            canonicalRootDirectory: canonicalRoot
        )
    }

    private func fileResourceIdentifier(for rootDirectory: URL) -> String? {
        guard let value = try? rootDirectory.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        ).fileResourceIdentifier else {
            return nil
        }

        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        ), !data.isEmpty else {
            return nil
        }

        return data.base64EncodedString()
    }
}
