import Foundation

protocol DockerComposeControlling: Sendable {
    func read(root: URL) async throws -> ComposeProjectStatus?
    func start(root: URL, configurationName: String) async throws
    func stop(root: URL, configurationName: String, containerIDs: [String]) async throws
}

struct LocalDockerComposeController: DockerComposeControlling {
    private let runner: any LocalCommandRunning
    private let reader: any DockerComposeStatusReading
    private let executable: URL?

    init(runner: any LocalCommandRunning = ReadOnlyCommandRunner(),
         reader: any DockerComposeStatusReading = LocalDockerComposeStatusReader(),
         executable: URL? = nil) {
        self.runner = runner
        self.reader = reader
        self.executable = executable
    }

    func read(root: URL) async throws -> ComposeProjectStatus? {
        try await reader.read(root: root)
    }

    func start(root: URL, configurationName: String) async throws {
        guard ProjectProfile.validComposeName(configurationName) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        let (docker, host) = try await localDocker()
        let arguments = ["--host", host, "compose", "--project-directory", root.path,
                         "-f", root.appendingPathComponent(configurationName).path,
                         "up", "--detach", "--no-build", "--pull", "never", "--no-recreate"]
        let output = try await runner.run(LocalCommand(executable: docker, arguments: arguments,
                                                       directory: root, timeout: 60, outputLimit: 256 * 1_024))
        guard output.exitCode == 0 else { throw LocalDockerComposeStatusReader.failure(for: output) }
    }

    func stop(root: URL, configurationName: String, containerIDs: [String]) async throws {
        guard ProjectProfile.validComposeName(configurationName), !containerIDs.isEmpty,
              Set(containerIDs).count == containerIDs.count,
              containerIDs.allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy { byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              } }) else { throw LocalReadFailure(kind: .invalidOutput) }
        let status = try await reader.read(root: root)
        guard status?.configurationName == configurationName,
              let containers = status?.containers,
              containerIDs.allSatisfy({ id in containers.contains { $0.id == id } }) else {
            throw LocalReadFailure(kind: .dockerAttributionUncertain)
        }
        let active = containers.filter { containerIDs.contains($0.id)
            && $0.state != .exited && $0.state != .dead }.map(\.id)
        guard !active.isEmpty else { return }
        let (docker, host) = try await localDocker()
        // The reader re-inspected every complete ID and verified Compose labels and paths.
        // Stop only that exact subset, never an entire Compose project by name.
        let output = try await runner.run(LocalCommand(executable: docker,
            arguments: ["--host", host, "stop", "--time", "5"] + active,
            timeout: 15, outputLimit: 128 * 1_024))
        guard output.exitCode == 0 else { throw LocalDockerComposeStatusReader.failure(for: output) }
    }

    private func localDocker() async throws -> (URL, String) {
        guard let docker = executable ?? LocalDockerComposeStatusReader.installedDocker() else {
            throw LocalReadFailure(kind: .dockerNotInstalled)
        }
        let output = try await runner.run(LocalCommand(executable: docker, arguments: ["context", "inspect"],
                                                       timeout: 5, outputLimit: 128 * 1_024))
        guard output.exitCode == 0 else { throw LocalDockerComposeStatusReader.failure(for: output) }
        return (docker, try LocalDockerComposeStatusReader.localHost(from: output.standardOutput))
    }
}
