import Foundation

protocol ProjectReadinessProbing: Sendable {
    func probe(_ url: URL) async throws -> Bool
}

struct LoopbackHTTPReadinessProbe: ProjectReadinessProbing {
    var runner: any LocalCommandRunning = ReadOnlyCommandRunner()

    static func accepts(_ url: URL) -> Bool {
        ProjectProfile.validReadinessURL(url)
    }

    func probe(_ url: URL) async throws -> Bool {
        guard Self.accepts(url) else { throw ProjectExecutionFailure.missingReadinessURL }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var arguments = ["-q", "--noproxy", "*", "--max-redirs", "0", "--max-time", "2",
                         "--silent", "--output", "/dev/null", "--write-out", "%{http_code}"]
        if parts.host?.lowercased() == "localhost", let port = parts.port {
            arguments += ["--resolve", "localhost:\(port):127.0.0.1"]
        }
        arguments.append(url.absoluteString)
        let output = try await runner.run(LocalCommand(executable: URL(fileURLWithPath: "/usr/bin/curl"),
                                                       arguments: arguments, timeout: 3, outputLimit: 1_024))
        guard output.exitCode == 0 else { return false }
        let code = String(decoding: output.standardOutput, as: UTF8.self)
        guard let status = Int(code), (100...599).contains(status) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        return (200...299).contains(status)
    }
}

enum NPMExecutableResolver {
    static func resolve() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let versions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versionNames = (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []
        let candidates = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]
            + versionNames.sorted(by: >).map { versions.appendingPathComponent("\($0)/bin/npm").path }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }
}
