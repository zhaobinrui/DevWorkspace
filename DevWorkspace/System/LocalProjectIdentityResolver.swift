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

        // 优先使用仓库声明的 ID，其次使用文件系统对象身份，最后才退化到规范化路径。
        // 这个顺序让项目移动时尽量保持身份稳定，同时避免仅凭名称合并不同项目。
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

        // 加入固定的领域与版本前缀做 domain separation，避免相同 seed 与其他哈希用途发生碰撞。
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

        // fileResourceIdentifier 是不透明对象，不能依赖 description 的未定义格式；安全归档后再
        // Base64 编码可得到结构化字节表示，归档失败则安全退化到规范路径。
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        ), !data.isEmpty else {
            return nil
        }

        return data.base64EncodedString()
    }
}
