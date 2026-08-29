import Foundation

struct ProjectIdentifier: Hashable, RawRepresentable, Sendable {
    // 前缀同时承担命名空间和格式版本职责，避免未来跨应用传递时把普通哈希误认成项目 ID。
    static let prefix = "devspace:project:v1:"
    private static let digestLength = 64
    private static let lowercaseHexDigits = Set("0123456789abcdef")

    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else {
            return nil
        }

        let digest = rawValue.dropFirst(Self.prefix.count)
        guard digest.count == Self.digestLength,
              digest.allSatisfy(Self.lowercaseHexDigits.contains)
        else {
            return nil
        }

        self.rawValue = rawValue
    }
}

extension ProjectIdentifier: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        guard let identifier = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid DevSpace project identifier"
            )
        }

        self = identifier
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ProjectIdentitySource: String, Codable, Sendable {
    case declaredMetadata
    case fileSystemResource
    case canonicalRoot
}

enum ProjectIdentityRelationship: Equatable, Sendable {
    case sameProject
    case distinctProjects
    case requiresUserResolution
}

struct ProjectIdentity: Codable, Hashable, Sendable {
    let identifier: ProjectIdentifier
    let source: ProjectIdentitySource
    let canonicalRootDirectory: URL

    func relationship(to candidate: Self) -> ProjectIdentityRelationship {
        guard identifier == candidate.identifier else {
            return .distinctProjects
        }

        // 稳定 ID 相同但根目录变化可能表示项目移动，也可能是错误绑定；危险操作前必须由用户确认。
        return canonicalRootDirectory == candidate.canonicalRootDirectory
            ? .sameProject
            : .requiresUserResolution
    }

    func acceptingRootDirectory(_ rootDirectory: URL) throws -> Self {
        guard rootDirectory.isFileURL else {
            throw ProjectIdentityError.nonFileURL
        }

        let canonicalRoot = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard !canonicalRoot.path.isEmpty else {
            throw ProjectIdentityError.missingRootPath
        }

        // 该方法只在用户确认移动后更新路径，保留原稳定 ID，避免跨应用引用因目录变化而失效。
        return Self(
            identifier: identifier,
            source: source,
            canonicalRootDirectory: canonicalRoot
        )
    }
}

enum ProjectIdentityError: LocalizedError, Equatable, Sendable {
    case nonFileURL
    case missingRootPath

    var errorDescription: String? {
        switch self {
        case .nonFileURL:
            "Project roots must use local file URLs."
        case .missingRootPath:
            "Project roots must have a non-empty path."
        }
    }
}

protocol ProjectIdentityResolving: Sendable {
    func resolve(
        rootDirectory: URL,
        declaredMetadataID: UUID?
    ) throws -> ProjectIdentity
}
