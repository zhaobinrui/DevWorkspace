import Foundation

protocol DockerComposeStatusReading: Sendable {
    func read(root: URL) async throws -> ComposeProjectStatus?
}

struct LocalDockerComposeStatusReader: DockerComposeStatusReading {
    private let runner: any LocalCommandRunning
    private let executable: URL?
    private static let composeNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    init(runner: any LocalCommandRunning = ReadOnlyCommandRunner(), executable: URL? = nil) {
        self.runner = runner
        self.executable = executable
    }

    func read(root: URL) async throws -> ComposeProjectStatus? {
        let discovery = try await LocalProjectConfigurationReader().read(root: root)
        if let issue = discovery.issues.first(where: { Self.composeNames.contains($0.source) }) {
            throw issue.failure
        }
        guard let name = Self.composeNames.first(where: { discovery.dockerFiles.contains($0) }) else { return nil }
        guard let docker = executable ?? Self.installedDocker() else {
            throw LocalReadFailure(kind: .dockerNotInstalled)
        }
        // Docker's selected context can be remote. Resolve it locally, then pin the observation
        // to its Unix socket so a changed context cannot redirect project data over the network.
        let context = try await runner.run(LocalCommand(executable: docker, arguments: ["context", "inspect"], timeout: 5,
                                                       outputLimit: 128 * 1_024))
        guard context.exitCode == 0 else { throw Self.failure(for: context) }
        let host = try Self.localHost(from: context.standardOutput)
        let arguments = ["--host", host, "compose", "--project-directory", root.path,
                         "-f", root.appendingPathComponent(name).path,
                         "ps", "--all", "--orphans=false", "--format", "json"]
        let output = try await runner.run(LocalCommand(executable: docker, arguments: arguments,
                                                       directory: root, timeout: 8, outputLimit: 512 * 1_024))
        guard output.exitCode == 0 else { throw Self.failure(for: output) }
        let containers = try Self.parse(output.standardOutput)
        if !containers.isEmpty {
            let inspectArguments = ["--host", host, "inspect", "--type", "container", "--format",
                                    "{{.Id}} {{json .Config.Labels}}"] + containers.map(\.id)
            let inspect = try await runner.run(LocalCommand(executable: docker, arguments: inspectArguments,
                                                            timeout: 8, outputLimit: 256 * 1_024))
            guard inspect.exitCode == 0 else { throw Self.failure(for: inspect) }
            try Self.verifyAttribution(inspect.standardOutput, containers: containers, root: root,
                                       configurationName: name)
        }
        let projectName = containers.first?.projectName
        return ComposeProjectStatus(configurationName: name, projectName: projectName, containers: containers)
    }

    private static func installedDocker() -> URL? {
        // These are fixed installation locations, never a PATH lookup in an untrusted repository.
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
         "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func localHost(from data: Data) throws -> String {
        struct Context: Decodable {
            struct Endpoints: Decodable { struct Docker: Decodable { let Host: String }; let docker: Docker }
            let Endpoints: Endpoints
        }
        guard let contexts = try? JSONDecoder().decode([Context].self, from: data),
              contexts.count == 1 else { throw LocalReadFailure(kind: .invalidOutput) }
        let host = contexts[0].Endpoints.docker.Host
        guard host.hasPrefix("unix:///"), host.count > "unix:///".count,
              !host.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw LocalReadFailure(kind: .dockerRemoteContext)
        }
        return host
    }

    static func parse(_ data: Data) throws -> [ComposeContainer] {
        guard let text = String(data: data, encoding: .utf8) else { throw LocalReadFailure(kind: .invalidOutput) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let rows: [[String: Any]]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = array
        } else {
            rows = try text.split(whereSeparator: \.isNewline).map { line in
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw LocalReadFailure(kind: .invalidOutput)
                }
                return row
            }
        }
        var containers: [ComposeContainer] = []
        var projectName: String?
        var identities = Set<String>()
        for row in rows {
            guard let id = row["ID"] as? String, (12...64).contains(id.count),
                  id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let project = row["Project"] as? String, !project.isEmpty,
                  let service = row["Service"] as? String, !service.isEmpty,
                  let stateText = row["State"] as? String,
                  let state = ComposeContainerState(rawValue: stateText),
                  identities.insert(id).inserted,
                  projectName == nil || projectName == project else { throw LocalReadFailure(kind: .invalidOutput) }
            projectName = project
            let healthText = row["Health"] as? String ?? ""
            guard healthText.isEmpty || ComposeContainerHealth(rawValue: healthText) != nil else {
                throw LocalReadFailure(kind: .invalidOutput)
            }
            guard let publisherValue = row["Publishers"],
                  publisherValue is NSNull || publisherValue is [[String: Any]] else {
                throw LocalReadFailure(kind: .invalidOutput)
            }
            let publishers = publisherValue as? [[String: Any]] ?? []
            let ports = try publishers.compactMap { publisher -> ComposePublishedPort? in
                guard let target = publisher["TargetPort"] as? Int, let published = publisher["PublishedPort"] as? Int,
                      (1...65_535).contains(target), (0...65_535).contains(published),
                      let transport = publisher["Protocol"] as? String,
                      ["tcp", "udp", "sctp"].contains(transport),
                      let address = publisher["URL"] as? String else { throw LocalReadFailure(kind: .invalidOutput) }
                // Compose can report an exposed target with PublishedPort 0. It is not a host endpoint.
                guard published != 0 else { return nil }
                return ComposePublishedPort(address: address, target: UInt16(target),
                                            published: UInt16(published), transport: transport)
            }
            containers.append(ComposeContainer(id: id, projectName: project, serviceName: service,
                                               state: state, health: ComposeContainerHealth(rawValue: healthText), ports: ports))
        }
        return containers.sorted { ($0.serviceName, $0.id) < ($1.serviceName, $1.id) }
    }

    static func verifyAttribution(_ data: Data, containers: [ComposeContainer], root: URL,
                                  configurationName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw LocalReadFailure(kind: .invalidOutput) }
        let rows = text.split(whereSeparator: \.isNewline)
        guard rows.count == containers.count else { throw LocalReadFailure(kind: .dockerAttributionUncertain) }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalConfig = root.appendingPathComponent(configurationName).standardizedFileURL
            .resolvingSymlinksInPath().path
        for (index, row) in rows.enumerated() {
            guard let separator = row.firstIndex(of: " "),
                  let labels = try? JSONSerialization.jsonObject(with: Data(row[row.index(after: separator)...].utf8)) as? [String: String] else {
                throw LocalReadFailure(kind: .invalidOutput)
            }
            let id = String(row[..<separator])
            let container = containers[index]
            // Compose ps abbreviates IDs while inspect expands them. Require a complete inspect ID
            // whose prefix matches the ps ID; Docker rejects ambiguous abbreviated IDs itself.
            guard id.count == 64, id.hasPrefix(container.id),
                  labels["com.docker.compose.project"] == container.projectName,
                  labels["com.docker.compose.service"] == container.serviceName else {
                throw LocalReadFailure(kind: .dockerAttributionUncertain)
            }
            let workingDirectory = labels["com.docker.compose.project.working_dir"]
            let configFiles = labels["com.docker.compose.project.config_files"]
            let directoryMatches = workingDirectory.map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == canonicalRoot
            }
            let fileMatches = configFiles.map { files in
                files.split(separator: ",").contains {
                    URL(fileURLWithPath: String($0)).standardizedFileURL.resolvingSymlinksInPath().path == canonicalConfig
                }
            }
            // A project name is not unique to a directory. Require at least one matching path
            // label, and reject any contradictory path label before claiming ownership.
            guard directoryMatches != false, fileMatches != false,
                  directoryMatches == true || fileMatches == true else {
                throw LocalReadFailure(kind: .dockerAttributionUncertain)
            }
        }
    }

    static func failure(for output: LocalCommandOutput) -> LocalReadFailure {
        if output.failure.kind == .permissionDenied { return output.failure }
        // Error text is classified in memory only; Compose may echo secrets from an .env file.
        let diagnostic = String(decoding: output.standardError, as: UTF8.self).lowercased()
        if diagnostic.contains("cannot connect to the docker daemon") || diagnostic.contains("is the docker daemon running")
            || diagnostic.contains("failed to connect to the docker api") || diagnostic.contains("daemon is running")
            || diagnostic.contains("error during connect") || diagnostic.contains("connection refused") {
            return LocalReadFailure(kind: .dockerDaemonUnavailable)
        }
        if diagnostic.contains("'compose' is not a docker command") {
            return LocalReadFailure(kind: .dockerComposeUnavailable)
        }
        return LocalReadFailure(kind: .unavailable)
    }
}
