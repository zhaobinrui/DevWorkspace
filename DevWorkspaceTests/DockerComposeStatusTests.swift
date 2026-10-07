import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class DockerComposeStatusTests: XCTestCase {
    func test_liveDockerAcceptance_whenEnabled_shouldReadCurrentComposeState() async throws {
        let marker = URL(fileURLWithPath: "/private/tmp/DevWorkspaceComposeAcceptance.json")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Live Docker acceptance requires an explicit temporary project")
        }
        // Xcode launches GUI tests separately and does not reliably forward the invoking shell's
        // environment. This opt-in marker is created and removed by the acceptance run.
        let acceptance = try JSONDecoder().decode(LiveAcceptance.self, from: Data(contentsOf: marker))
        let reading = try await LocalDockerComposeStatusReader().read(root: URL(fileURLWithPath: acceptance.root))
        let status = try XCTUnwrap(reading)
        XCTAssertEqual(status.configurationName, "compose.yaml")
        switch acceptance.state {
        case "running":
            XCTAssertEqual(status.containers.map(\.serviceName), ["api", "worker"])
            XCTAssertEqual(status.containers.map(\.state), [.running, .running])
            XCTAssertEqual(status.containers.map(\.health), [.healthy, .unhealthy])
            XCTAssertEqual(status.containers[0].ports.count, 1)
            XCTAssertEqual(status.containers[0].ports.first?.address, "127.0.0.1")
            XCTAssertEqual(status.containers[0].ports.first?.target, 8080)
            XCTAssertGreaterThan(status.containers[0].ports.first?.published ?? 0, 0)
        case "stopped":
            XCTAssertEqual(status.containers.map(\.state), [.exited, .exited])
        case "empty":
            XCTAssertTrue(status.containers.isEmpty)
        default:
            XCTFail("Unknown acceptance state: \(acceptance.state)")
        }
    }

    private struct LiveAcceptance: Decodable {
        let root: String
        let state: String
    }

    func test_read_whenComposePresent_shouldUseLocalSocketAndRetainAttributionEvidence() async throws {
        let root = try temporaryProject(files: ["compose.yaml"])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = """
        {"ID":"abc1234567890123","Project":"sample","Service":"api","State":"running","Health":"healthy","Publishers":[{"URL":"127.0.0.1","TargetPort":8080,"PublishedPort":18080,"Protocol":"tcp"}]}
        {"ID":"def1234567890123","Project":"sample","Service":"db","State":"exited","Health":"","Publishers":null}
        """
        let labels = try inspectedLabels(root: root, configurationName: "compose.yaml",
                                         containers: [("abc1234567890123", "api"), ("def1234567890123", "db")])
        let runner = DockerCommandFixture(outputs: [.success(contextOutput()), .success(commandOutput(output)),
                                                    .success(commandOutput(labels))])
        let value = try await LocalDockerComposeStatusReader(runner: runner, executable: dockerURL).read(root: root)
        let status = try XCTUnwrap(value)
        XCTAssertEqual(status.configurationName, "compose.yaml")
        XCTAssertEqual(status.projectName, "sample")
        XCTAssertEqual(status.containers.map(\.serviceName), ["api", "db"])
        XCTAssertEqual(status.containers.map(\.state), [.running, .exited])
        XCTAssertEqual(status.containers[0].health, .healthy)
        XCTAssertEqual(status.containers[0].ports,
                       [ComposePublishedPort(address: "127.0.0.1", target: 8080, published: 18080, transport: "tcp")])
        let commands = await runner.calls()
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0].arguments, ["context", "inspect"])
        XCTAssertEqual(commands[1].arguments, ["--host", "unix:///var/run/docker.sock", "compose",
                                               "--project-directory", root.path, "-f", root.appendingPathComponent("compose.yaml").path,
                                               "ps", "--all", "--orphans=false", "--format", "json"])
        XCTAssertEqual(commands[1].directory, root)
        XCTAssertEqual(commands[2].arguments, ["--host", "unix:///var/run/docker.sock", "inspect", "--type",
                                               "container", "--format", "{{.Id}} {{json .Config.Labels}}",
                                               "abc1234567890123", "def1234567890123"])
        XCTAssertTrue(commands.allSatisfy { $0.executable == dockerURL })
    }

    func test_read_whenOnlyDockerfileOrNoConfig_shouldNotContactDocker() async throws {
        let root = try temporaryProject(files: ["Dockerfile"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DockerCommandFixture(outputs: [])
        let reader = LocalDockerComposeStatusReader(runner: runner, executable: dockerURL)
        let status = try await reader.read(root: root)
        XCTAssertNil(status)
        let firstCalls = await runner.calls()
        XCTAssertTrue(firstCalls.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Dockerfile"))
        let empty = try await reader.read(root: root)
        XCTAssertNil(empty)
        let secondCalls = await runner.calls()
        XCTAssertTrue(secondCalls.isEmpty)
    }

    func test_read_whenNoContainers_shouldReportSuccessfulEmptyState() async throws {
        let root = try temporaryProject(files: ["docker-compose.yml"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DockerCommandFixture(outputs: [.success(contextOutput()), .success(commandOutput("\n"))])
        let value = try await LocalDockerComposeStatusReader(runner: runner, executable: dockerURL).read(root: root)
        let status = try XCTUnwrap(value)
        XCTAssertEqual(status.configurationName, "docker-compose.yml")
        XCTAssertNil(status.projectName)
        XCTAssertTrue(status.containers.isEmpty)
    }

    func test_read_whenRemoteContext_shouldRejectBeforeComposeCommand() async throws {
        let root = try temporaryProject(files: ["compose.yml"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DockerCommandFixture(outputs: [.success(contextOutput(host: "ssh://server"))])
        do {
            _ = try await LocalDockerComposeStatusReader(runner: runner, executable: dockerURL).read(root: root)
            XCTFail("Remote Docker context must be rejected")
        } catch let failure as LocalReadFailure {
            XCTAssertEqual(failure.kind, .dockerRemoteContext)
        }
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func test_read_whenDaemonDeniedTimedOutOrUnavailable_shouldClassifyFailure() async throws {
        let root = try temporaryProject(files: ["compose.yaml"])
        defer { try? FileManager.default.removeItem(at: root) }
        for (result, expected) in [
            (Result<LocalCommandOutput, LocalReadFailure>.success(commandOutput("", error: "Cannot connect to the Docker daemon", exitCode: 1)), LocalFailureKind.dockerDaemonUnavailable),
            (.success(commandOutput("", error: "failed to connect to the docker API at unix:///tmp/docker.sock; check if the daemon is running", exitCode: 1)), .dockerDaemonUnavailable),
            (.success(commandOutput("", error: "permission denied while trying to connect", exitCode: 1)), .permissionDenied),
            (.failure(LocalReadFailure(kind: .timedOut)), .timedOut),
            (.success(commandOutput("", error: "docker: 'compose' is not a docker command", exitCode: 1)), .dockerComposeUnavailable),
        ] {
            let runner = DockerCommandFixture(outputs: [.success(contextOutput()), result])
            do {
                _ = try await LocalDockerComposeStatusReader(runner: runner, executable: dockerURL).read(root: root)
                XCTFail("Expected \(expected)")
            } catch let failure as LocalReadFailure {
                XCTAssertEqual(failure.kind, expected)
            }
        }
    }

    func test_parser_whenProtocolChangesOrProjectMixed_shouldRejectEntireReading() {
        let rows = [
            #"{"ID":"one","Project":"a","Service":"api","State":"running","Health":"","Publishers":null}"#,
            #"{"ID":"two","Project":"b","Service":"db","State":"running","Health":"","Publishers":null}"#,
        ]
        for text in ["not-json", "{}", #"{"ID":"one","Project":"a","Service":"api","State":"mystery","Health":""}"#,
                     rows.joined(separator: "\n")] {
            XCTAssertThrowsError(try LocalDockerComposeStatusReader.parse(Data(text.utf8)))
        }
        let exposedOnly = #"{"ID":"abc1234567890123","Project":"a","Service":"api","State":"running","Health":"","Publishers":[{"URL":"","TargetPort":8080,"PublishedPort":0,"Protocol":"tcp"}]}"#
        XCTAssertEqual(try? LocalDockerComposeStatusReader.parse(Data(exposedOnly.utf8)).first?.ports, [])
    }

    func test_read_whenMatchingProjectNameButDifferentDirectory_shouldRejectAttribution() async throws {
        let root = try temporaryProject(files: ["compose.yaml"])
        defer { try? FileManager.default.removeItem(at: root) }
        let row = #"{"ID":"abc1234567890123","Project":"sample","Service":"api","State":"running","Health":"","Publishers":null}"#
        let wrongRoot = URL(fileURLWithPath: "/private/tmp/unrelated-project")
        let labels = try inspectedLabels(root: wrongRoot, configurationName: "compose.yaml",
                                         containers: [("abc1234567890123", "api")])
        let runner = DockerCommandFixture(outputs: [.success(contextOutput()), .success(commandOutput(row)),
                                                    .success(commandOutput(labels))])
        do {
            _ = try await LocalDockerComposeStatusReader(runner: runner, executable: dockerURL).read(root: root)
            XCTFail("A matching Compose name cannot establish directory ownership")
        } catch let failure as LocalReadFailure {
            XCTAssertEqual(failure.kind, .dockerAttributionUncertain)
        }
        let weakLabels = #"abc1234567890123 {"com.docker.compose.project":"sample","com.docker.compose.service":"api"}"#
        XCTAssertThrowsError(try LocalDockerComposeStatusReader.verifyAttribution(
            Data(weakLabels.utf8), containers: LocalDockerComposeStatusReader.parse(Data(row.utf8)),
            root: root, configurationName: "compose.yaml")) { error in
                XCTAssertEqual((error as? LocalReadFailure)?.kind, .dockerAttributionUncertain)
            }
        let wrongID = String(repeating: "f", count: 64) + " " +
            #"{"com.docker.compose.project":"sample","com.docker.compose.service":"api","com.docker.compose.project.working_dir":"\#(root.path)"}"#
        XCTAssertThrowsError(try LocalDockerComposeStatusReader.verifyAttribution(
            Data(wrongID.utf8), containers: LocalDockerComposeStatusReader.parse(Data(row.utf8)),
            root: root, configurationName: "compose.yaml")) { error in
                XCTAssertEqual((error as? LocalReadFailure)?.kind, .dockerAttributionUncertain)
            }
    }

    func test_readings_whenComposeFails_shouldKeepTrustedStatusAndTimestamp() {
        let date = Date(timeIntervalSince1970: 100)
        let previous = WorkspaceReadings(git: .success(nil, at: date), ports: .success([], at: date),
                                         compose: .success(ComposeProjectStatus(configurationName: "compose.yaml",
                                                                               projectName: nil, containers: []), at: date))
        let attempted = Date(timeIntervalSince1970: 200)
        let current = WorkspaceReadings(git: .success(nil, at: attempted), ports: .success([], at: attempted),
                                        compose: .failed(LocalReadFailure(kind: .permissionDenied), at: attempted))
        let merged = current.retainingTrustedValues(from: previous)
        XCTAssertTrue(merged.hasFailure)
        XCTAssertEqual(merged.compose?.value, previous.compose?.value)
        XCTAssertEqual(merged.compose?.checkedAt, date)
        XCTAssertEqual(merged.compose?.attemptedAt, attempted)
        XCTAssertNil(WorkspaceReadings(git: current.git, ports: current.ports)
            .retainingTrustedValues(from: previous).compose)
    }

    private var dockerURL: URL { URL(fileURLWithPath: "/usr/local/bin/docker") }

    private func temporaryProject(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files { try Data("services: {}".utf8).write(to: root.appendingPathComponent(file)) }
        return root
    }

    private func contextOutput(host: String = "unix:///var/run/docker.sock") -> LocalCommandOutput {
        commandOutput(#"[{"Endpoints":{"docker":{"Host":"\#(host)"}}}]"#)
    }

    private func commandOutput(_ stdout: String, error: String = "", exitCode: Int32 = 0) -> LocalCommandOutput {
        LocalCommandOutput(standardOutput: Data(stdout.utf8), standardError: Data(error.utf8), exitCode: exitCode)
    }

    private func inspectedLabels(root: URL, configurationName: String,
                                 containers: [(String, String)]) throws -> String {
        try containers.map { id, service in
            let labels = ["com.docker.compose.project": "sample", "com.docker.compose.service": service,
                          "com.docker.compose.project.working_dir": root.path,
                          "com.docker.compose.project.config_files": root.appendingPathComponent(configurationName).path]
            let data = try JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys])
            let fullID = id + String(repeating: "a", count: 64 - id.count)
            return fullID + " " + String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }
}

private actor DockerCommandFixture: LocalCommandRunning {
    private var outputs: [Result<LocalCommandOutput, LocalReadFailure>]
    private var commands: [LocalCommand] = []

    init(outputs: [Result<LocalCommandOutput, LocalReadFailure>]) { self.outputs = outputs }

    func run(_ command: LocalCommand) async throws -> LocalCommandOutput {
        commands.append(command)
        guard !outputs.isEmpty else { throw LocalReadFailure(kind: .invalidOutput) }
        return try outputs.removeFirst().get()
    }

    func calls() -> [LocalCommand] { commands }
}
