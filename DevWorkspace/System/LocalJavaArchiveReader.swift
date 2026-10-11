import CryptoKit
import Darwin
import Foundation

struct JavaArchiveSource: Codable, Equatable, Sendable {
    let digest: String
    let byteCount: Int64
}

protocol JavaArchiveReading: Sendable {
    func read(root: URL, archive: ProfileJavaArchive) async throws -> JavaArchiveSource
}

struct LocalJavaArchiveReader: JavaArchiveReading {
    func read(root: URL, archive: ProfileJavaArchive) async throws -> JavaArchiveSource {
        guard archive.isValid else { throw ProfileFailure.invalidProfile }
        return try await Task.detached(priority: .utility) {
            try Self.hash(root: root, relativePath: archive.relativePath)
        }.value
    }

    private static func hash(root: URL, relativePath: String) throws -> JavaArchiveSource {
        let parts = relativePath.split(separator: "/").map(String.init)
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalReadFailure(kind: .permissionDenied) }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw LocalReadFailure(kind: .invalidDirectory) }
            close(parent)
            parent = next
        }
        guard let last = parts.last else { throw ProfileFailure.invalidProfile }
        let fd = openat(parent, last, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalReadFailure(kind: .unavailable) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= 1_073_741_824 else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        var hash = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw LocalReadFailure(kind: .unavailable) }
            if count == 0 { break }
            total += Int64(count)
            guard total <= 1_073_741_824 else { throw LocalReadFailure(kind: .outputLimit) }
            hash.update(data: Data(buffer.prefix(count)))
        }
        // A concurrent rebuild must not turn a preview of one JAR into trust for another.
        var after = stat()
        guard fstat(fd, &after) == 0, total == after.st_size,
              info.st_dev == after.st_dev, info.st_ino == after.st_ino,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ProfileFailure.reviewChanged
        }
        return JavaArchiveSource(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                                 byteCount: total)
    }
}
