import Darwin
import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class LocalSystemAdapterTests: XCTestCase {
    func test_gitParser_whenPathsContainNewlinesAndRename_shouldCountRecordsOnce() throws {
        let records = [
            "# branch.oid abc123", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -3",
            "1 .M N... 100644 100644 100644 abc abc file with spaces",
            "2 R. N... 100644 100644 100644 abc abc R100 new\nname", "old\nname",
            "? untracked\nfile", "u UU N... 100644 100644 100644 100644 a b c conflict",
        ]
        let result = try GitStatusParser.parse(nul(records))
        XCTAssertEqual(result.changedFileCount, 4)
        XCTAssertEqual(result.commitsAhead, 2)
        XCTAssertEqual(result.commitsBehind, 3)
        XCTAssertEqual(result.upstream, "origin/main")
        XCTAssertTrue(result.hasDivergence)
    }

    func test_gitParser_whenUpstreamRefIsMissing_shouldNotClaimZeroDivergence() throws {
        let result = try GitStatusParser.parse(nul(["# branch.oid abc123", "# branch.head main", "# branch.upstream origin/main"]))
        XCTAssertEqual(result.upstream, "origin/main")
        XCTAssertFalse(result.hasDivergence)
    }

    func test_gitParser_whenCleanDetachedOrUnborn_shouldExposeAccurateStates() throws {
        let clean = try GitStatusParser.parse(nul(["# branch.oid abcdef1234", "# branch.head main"]))
        XCTAssertEqual(clean.changedFileCount, 0)
        XCTAssertNil(clean.upstream)
        let detached = try GitStatusParser.parse(nul(["# branch.oid abcdef1234", "# branch.head (detached)"]))
        XCTAssertTrue(detached.isDetached)
        XCTAssertEqual(detached.branch, "abcdef12")
        let unborn = try GitStatusParser.parse(nul(["# branch.oid (initial)", "# branch.head main", "? new"]))
        XCTAssertTrue(unborn.isUnborn)
    }

    func test_gitParser_whenProtocolChangesOrIsTruncated_shouldReject() {
        for data in [Data(), Data("# branch.head main".utf8), nul(["# branch.head main", "3 unknown"]),
                     nul(["# branch.head main", "# branch.oid abc", "# branch.ab +x -0"]),
                     nul(["# branch.head main", "# branch.oid abc", "2 R. N... 100644 100644 100644 a a R100 new"])] {
            XCTAssertThrowsError(try GitStatusParser.parse(data))
        }
    }

    func test_gitReader_whenFiltersAreConfigured_shouldDisableExecutableHelpers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let runner = FixtureCommandRunner([
            .output(commandOutput(nul(["filter.danger.process", "filter.danger.clean"]))),
            .output(commandOutput(nul(["# branch.oid abc", "# branch.head main"]))),
        ])
        _ = try await LocalGitStatusReader(runner: runner).status(for: testProject(directory))
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?.executable.path, "/usr/bin/git")
        for argument in ["core.fsmonitor=false", "core.hooksPath=/dev/null", "filter.danger.process=", "filter.danger.clean=", "filter.danger.required=false", "--ignore-submodules=all", "-z"] {
            XCTAssertTrue(commands.last?.arguments.contains(argument) == true, argument)
        }
    }

    func test_gitReader_whenNonRepository_shouldReturnAbsentWithoutRunningCommands() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = FixtureCommandRunner([])
        let result = try await LocalGitStatusReader(runner: runner).status(for: testProject(directory))
        XCTAssertNil(result)
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func test_gitReader_whenPermissionDeniedOrTimedOut_shouldPreserveFailureKind() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        for kind in [LocalFailureKind.permissionDenied, .timedOut, .unavailable] {
            let reader = LocalGitStatusReader(runner: FixtureCommandRunner([.failure(kind)]))
            do { _ = try await reader.status(for: testProject(directory)); XCTFail("Expected failure") }
            catch let error as LocalReadFailure { XCTAssertEqual(error.kind, kind) }
        }
    }

    func test_lsofParser_whenTCPIPv6AndUDPClientsExist_shouldKeepOnlyBoundEndpoints() throws {
        let tcp = try LsofSocketParser.parse(nul(["p42", "cnode", "u501", "\nf8", "PTCP", "n[::1]:3000", "\nf9", "PTCP", "n*:3001"]) + Data("\n".utf8))
        XCTAssertEqual(tcp.first?.sockets.map(\.port), [3000, 3001])
        XCTAssertEqual(tcp.first?.sockets.first?.address, "[::1]")
        let udp = try LsofSocketParser.parse(nul(["p42", "cnode", "u501", "f8", "PUDP", "n*:5353", "f9", "PUDP", "n127.0.0.1:5000->127.0.0.1:53"]))
        XCTAssertEqual(udp.first?.sockets.count, 1)
        XCTAssertThrowsError(try LsofSocketParser.parse(nul(["p42", "cnode", "u501", "f8", "POTHER", "n*:3000"])))
        XCTAssertThrowsError(try LsofSocketParser.parse(Data("PID COMMAND\n42 node".utf8)))
        XCTAssertThrowsError(try LsofSocketParser.parse(nul(["p42", "cnode", "u501", "f8", "PTCP"])))
        XCTAssertThrowsError(try LsofSocketParser.parse(nul(["p42", "cnode", "u501", "f8", "PTCP"]) + Data("n*:30".utf8)))
    }

    func test_portScanner_whenNoMatches_shouldPublishAnEmptySuccess() async throws {
        let runner = FixtureCommandRunner([.output(commandOutput(exit: 1)), .output(commandOutput(exit: 1))])
        let result = try await LocalPortScanner(runner: runner).scan()
        XCTAssertTrue(result.isEmpty)
    }

    func test_portScanner_whenPermissionDeniedOrTimeout_shouldNotPublishEmptySuccess() async throws {
        let denied = FixtureCommandRunner([.output(commandOutput(error: "lsof: permission denied", exit: 1))])
        do { _ = try await LocalPortScanner(runner: denied).scan(); XCTFail("Expected permission failure") }
        catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .permissionDenied) }
        do { _ = try await LocalPortScanner(runner: FixtureCommandRunner([.failure(.timedOut)])).scan(); XCTFail("Expected timeout") }
        catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .timedOut) }
    }

    func test_portScanner_whenIdentityChanges_shouldRetryAndRejectReplacementOwner() async throws {
        let output = commandOutput(nul(["p42", "cnode", "u501", "f8", "PTCP", "n*:3000"]))
        let runner = FixtureCommandRunner([.output(output), .output(commandOutput(exit: 1)), .output(output), .output(commandOutput(exit: 1))])
        let process = testProcess(pid: 42, uid: 502)
        let scanner = LocalPortScanner(runner: runner, inspector: FixtureProcessInspector(process: process), userID: 501)
        do { _ = try await scanner.scan(); XCTFail("Expected identity rejection") }
        catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .processChanged) }
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 4)
    }

    func test_portScanner_whenIdentityIsStable_shouldKeepPathOwnerAndDeduplicateSockets() async throws {
        let output = commandOutput(nul(["p42", "cnode", "u501", "f8", "PTCP", "n*:3000", "f9", "PTCP", "n*:3000"]))
        let process = testProcess(pid: 42)
        let scanner = LocalPortScanner(runner: FixtureCommandRunner([.output(output), .output(commandOutput(exit: 1))]), inspector: FixtureProcessInspector(process: process), userID: 501)
        let result = try await scanner.scan()
        XCTAssertEqual(result.first?.identity, process.identity)
        XCTAssertEqual(result.first?.sockets.count, 1)
    }

    func test_nativeInspector_whenReadingSelf_shouldReturnCurrentOwnerExecutableAndDirectory() throws {
        let result = try NativeProcessInspector().inspect(pid: getpid())
        XCTAssertEqual(result.identity.userID, getuid())
        XCTAssertTrue(result.identity.executablePath.hasPrefix("/"))
        XCTAssertNotNil(result.workingDirectory)
    }

    func test_realPortScanner_whenOwnedTCPAndUDPPortsAreBound_shouldReportBothWithIdentity() async throws {
        let tcp = try boundSocket(type: SOCK_STREAM)
        let udp = try boundSocket(type: SOCK_DGRAM)
        defer { close(tcp.fd); close(udp.fd) }
        XCTAssertEqual(listen(tcp.fd, 1), 0)
        let processes = try await LocalPortScanner().scan()
        let process = try XCTUnwrap(processes.first { $0.identity.pid == getpid() })
        XCTAssertEqual(process.identity.userID, getuid())
        XCTAssertTrue(process.sockets.contains { $0.transport == .tcp && $0.port == tcp.port })
        XCTAssertTrue(process.sockets.contains { $0.transport == .udp && $0.port == udp.port })
        XCTAssertNotNil(process.workingDirectory)
    }

    private func boundSocket(type: Int32) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw LocalReadFailure(kind: .unavailable) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { close(fd); throw LocalReadFailure(kind: .unavailable) }
        let retrieved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard retrieved == 0 else { close(fd); throw LocalReadFailure(kind: .unavailable) }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    func test_commandRunner_whenTimedOutCancelledOrOutputLimited_shouldEndOwnedChild() async throws {
        let runner = ReadOnlyCommandRunner()
        do {
            _ = try await runner.run(LocalCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.06))
            XCTFail("Expected timeout")
        } catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .timedOut) }
        let task = Task { try await runner.run(LocalCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"])) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        do {
            _ = try await runner.run(LocalCommand(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], outputLimit: 1024))
            XCTFail("Expected bounded output")
        } catch let failure as LocalReadFailure { XCTAssertEqual(failure.kind, .outputLimit) }
    }

    func test_realGit_whenProjectHasSpacesAndUnbornBranch_shouldResolveRootAndReadStatus() async throws {
        let directory = try temporaryDirectory(name: "project with spaces")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = LocalGitClient(runner: ReadOnlyCommandRunner())
        try await client.run(at: directory, arguments: ["init", "-b", "main"]).requireSuccess()
        let child = directory.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("sample".utf8).write(to: child.appendingPathComponent("file\nname.txt"))
        let project = try await LocalProjectRootResolver().project(at: child)
        XCTAssertEqual(project.rootDirectory, directory.standardizedFileURL.resolvingSymlinksInPath())
        let status = try await LocalGitStatusReader().status(for: project)
        XCTAssertEqual(status?.branch, "main")
        XCTAssertEqual(status?.changedFileCount, 1)
        XCTAssertTrue(status?.isUnborn == true)
    }
}

enum FixtureCommandStep: Sendable { case output(LocalCommandOutput), failure(LocalFailureKind) }

actor FixtureCommandRunner: LocalCommandRunning {
    private var steps: [FixtureCommandStep]
    private(set) var commands: [LocalCommand] = []
    init(_ steps: [FixtureCommandStep]) { self.steps = steps }
    func run(_ command: LocalCommand) async throws -> LocalCommandOutput {
        commands.append(command)
        guard !steps.isEmpty else { throw LocalReadFailure(kind: .unavailable) }
        switch steps.removeFirst() {
        case let .output(output): return output
        case let .failure(kind): throw LocalReadFailure(kind: kind)
        }
    }
}

struct FixtureProcessInspector: ProcessInspecting {
    let process: ListeningProcess
    func inspect(pid: Int32) throws -> InspectedProcess {
        InspectedProcess(identity: process.identity, workingDirectory: process.workingDirectory, directoryFailure: process.directoryFailure)
    }
}

func nul(_ records: [String]) -> Data { Data((records.joined(separator: "\0") + "\0").utf8) }
func commandOutput(_ data: Data = Data(), error: String = "", exit: Int32 = 0) -> LocalCommandOutput {
    LocalCommandOutput(standardOutput: data, standardError: Data(error.utf8), exitCode: exit)
}
func temporaryDirectory(name: String = "project") throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("DevWorkspaceTests-\(UUID().uuidString)-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func testProject(_ directory: URL, id: UUID? = nil) throws -> ProjectReference {
    ProjectReference(identity: try LocalProjectIdentityResolver().resolve(rootDirectory: directory, declaredMetadataID: id), name: directory.lastPathComponent)
}
func testProcess(pid: Int32 = 42, uid: UInt32 = 501, start: UInt64 = 1, directory: String? = "/private/tmp/project") -> ListeningProcess {
    ListeningProcess(identity: ProcessIdentity(pid: pid, userID: uid, executablePath: "/usr/local/bin/node", startedSeconds: start, startedMicroseconds: 0),
                     name: "node", userName: "tester", workingDirectory: directory.map { URL(fileURLWithPath: $0, isDirectory: true) },
                     directoryFailure: directory == nil ? LocalReadFailure(kind: .permissionDenied) : nil,
                     sockets: [ListeningSocket(transport: .tcp, address: "127.0.0.1", port: 3000)])
}
