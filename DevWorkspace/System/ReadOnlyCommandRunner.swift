import Darwin
import Foundation

struct LocalCommand: Sendable {
    let executable: URL
    let arguments: [String]
    var directory: URL? = nil
    var timeout: TimeInterval = 8
    var outputLimit = 4 * 1_024 * 1_024
}

struct LocalCommandOutput: Sendable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32

    func requireSuccess() throws {
        guard exitCode == 0 else { throw failure }
    }

    var failure: LocalReadFailure {
        // Classify diagnostics without retaining command output, file names or potential secrets in UI/logs.
        let message = String(decoding: standardError, as: UTF8.self).lowercased()
        return LocalReadFailure(kind: message.contains("permission denied") || message.contains("operation not permitted")
            ? .permissionDenied : .unavailable)
    }
}

protocol LocalCommandRunning: Sendable {
    func run(_ command: LocalCommand) async throws -> LocalCommandOutput
}

struct ReadOnlyCommandRunner: LocalCommandRunning {
    func run(_ command: LocalCommand) async throws -> LocalCommandOutput {
        let cancellation = CommandCancellation()
        // Process I/O and wait operations run off MainActor; cancellation is shared only through a lock.
        let task = Task.detached(priority: .utility) {
            try Self.execute(command, cancellation: cancellation)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(_ command: LocalCommand, cancellation: CommandCancellation) throws -> LocalCommandOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        // Do not inherit GIT_DIR, injected config, credential helpers or a user-controlled PATH.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1",
        ]
        defer {
            // Only the child created by this Process is stopped. An unreaped child cannot have its PID reused.
            if process.isRunning {
                process.terminate()
                for _ in 0..<20 where process.isRunning { usleep(10_000) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { try process.run() } catch { throw LocalReadFailure.classify(error) }
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw LocalReadFailure(kind: .unavailable)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(command.timeout))
        var buffers = [Data(), Data()]
        var ended = [false, false]
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            if clock.now >= deadline { throw LocalReadFailure(kind: .timedOut) }
            for index in descriptors.indices where !ended[index] {
                // Bound each drain as well as total output so a continuously writing child cannot starve cancellation.
                for _ in 0..<16 {
                    let count = Darwin.read(descriptors[index], &bytes, bytes.count)
                    if count > 0 {
                        buffers[index].append(contentsOf: bytes.prefix(count))
                        if buffers[0].count + buffers[1].count > command.outputLimit {
                            throw LocalReadFailure(kind: .outputLimit)
                        }
                    } else if count == 0 {
                        ended[index] = true
                        break
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else if errno != EINTR {
                        throw LocalReadFailure(kind: .unavailable)
                    }
                }
            }
            if !process.isRunning && ended.allSatisfy({ $0 }) { break }
            usleep(10_000)
        }
        process.waitUntilExit()
        return LocalCommandOutput(standardOutput: buffers[0], standardError: buffers[1], exitCode: process.terminationStatus)
    }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
