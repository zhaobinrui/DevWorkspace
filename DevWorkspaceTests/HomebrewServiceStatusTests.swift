import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class HomebrewServiceStatusTests: XCTestCase {
    func test_reader_whenRunningAndStopped_shouldReturnCurrentUserStates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("homebrew.mxcl.redis.plist"))
        let runner = HomebrewCommandFixture(outputs: [
            "redis": LocalCommandOutput(standardOutput: Data("state = running\n    pid = 4321\n".utf8),
                                         standardError: Data(), exitCode: 0),
            "postgresql@17": LocalCommandOutput(standardOutput: Data(),
                standardError: Data("Could not find service".utf8), exitCode: 113),
        ])
        let reader = LocalHomebrewServiceStatusReader(runner: runner, agentsDirectory: directory, userID: 501)
        let statuses = try await reader.read(names: ["redis", "postgresql@17"])
        XCTAssertEqual(statuses, [HomebrewServiceStatus(name: "redis", state: .running, pid: 4321),
                                  HomebrewServiceStatus(name: "postgresql@17", state: .notRegistered, pid: nil)])
        let invocations = await runner.invocations
        XCTAssertEqual(invocations, ["gui/501/homebrew.mxcl.redis",
                                     "gui/501/homebrew.mxcl.postgresql@17"])
    }

    func test_reader_whenRegisteredButUnloaded_shouldReportStopped() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("homebrew.mxcl.redis.plist"))
        let output = LocalCommandOutput(standardOutput: Data(),
            standardError: Data("Could not find service".utf8), exitCode: 113)
        let reader = LocalHomebrewServiceStatusReader(runner: HomebrewCommandFixture(outputs: ["redis": output]),
                                                      agentsDirectory: directory)
        let statuses = try await reader.read(names: ["redis"])
        XCTAssertEqual(statuses,
                       [HomebrewServiceStatus(name: "redis", state: .stopped, pid: nil)])
    }

    func test_reader_whenOutputMalformedOrNameInvalid_shouldFailClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = LocalCommandOutput(standardOutput: Data("state = running\n".utf8),
                                        standardError: Data(), exitCode: 0)
        let reader = LocalHomebrewServiceStatusReader(runner: HomebrewCommandFixture(outputs: ["redis": output]),
                                                      agentsDirectory: directory)
        do {
            _ = try await reader.read(names: ["redis"])
            XCTFail("A running service without a PID is not trustworthy")
        } catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .invalidOutput) }
        do {
            _ = try await reader.read(names: ["redis; echo unsafe"])
            XCTFail("Invalid formula names must not reach launchctl")
        } catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .invalidOutput) }
    }

    func test_store_whenStatusReadFails_shouldPreserveSourceTimeAndFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try testProject(directory)
        let reader = HomebrewStatusFixture()
        let store = WorkspaceStore(project: project, provider: PreviewWorkspaceSnapshotProvider(),
                                   homebrewReader: reader)
        try store.saveProfileDraft(ProjectProfile(homebrewServices: ["redis"]), for: project.id)
        await store.refreshHomebrewServices()
        let first = try XCTUnwrap(store.homebrewServices)
        XCTAssertEqual(first.value?.first?.state, .running)
        await reader.failNextRead()
        await store.refreshHomebrewServices()
        let second = try XCTUnwrap(store.homebrewServices)
        XCTAssertEqual(second.value, first.value)
        XCTAssertEqual(second.checkedAt, first.checkedAt)
        XCTAssertEqual(second.failure?.kind, .permissionDenied)
        XCTAssertGreaterThanOrEqual(second.attemptedAt, first.attemptedAt)
    }
}

private actor HomebrewCommandFixture: LocalCommandRunning {
    private let outputs: [String: LocalCommandOutput]
    private(set) var invocations: [String] = []

    init(outputs: [String: LocalCommandOutput]) { self.outputs = outputs }

    func run(_ command: LocalCommand) async throws -> LocalCommandOutput {
        guard command.executable.path == "/bin/launchctl", command.arguments.count == 2,
              command.arguments[0] == "print" else { throw LocalReadFailure(kind: .invalidOutput) }
        invocations.append(command.arguments[1])
        let name = String(command.arguments[1].split(separator: ".").last ?? "")
        guard let output = outputs[name] else { throw LocalReadFailure(kind: .invalidOutput) }
        return output
    }
}

private actor HomebrewStatusFixture: HomebrewServiceStatusReading {
    private var shouldFail = false
    func failNextRead() { shouldFail = true }
    func read(names: [String]) async throws -> [HomebrewServiceStatus] {
        if shouldFail {
            shouldFail = false
            throw LocalReadFailure(kind: .permissionDenied)
        }
        return names.map { HomebrewServiceStatus(name: $0, state: .running, pid: 123) }
    }
}
