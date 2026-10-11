import Darwin
import Foundation

struct LocalHomebrewServiceStatusReader: HomebrewServiceStatusReading {
    private let runner: any LocalCommandRunning
    private let agentsDirectory: URL
    private let userID: UInt32

    init(runner: any LocalCommandRunning = ReadOnlyCommandRunner(),
         agentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
         userID: UInt32 = getuid()) {
        self.runner = runner
        self.agentsDirectory = agentsDirectory
        self.userID = userID
    }

    func read(names: [String]) async throws -> [HomebrewServiceStatus] {
        guard names.allSatisfy(ProjectProfile.validHomebrewName) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        var statuses: [HomebrewServiceStatus] = []
        for name in names {
            try Task.checkCancellation()
            let label = "homebrew.mxcl.\(name)"
            let command = LocalCommand(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                       arguments: ["print", "gui/\(userID)/\(label)"],
                                       timeout: 3, outputLimit: 64 * 1_024)
            let output = try await runner.run(command)
            if output.exitCode == 113,
               String(decoding: output.standardError, as: UTF8.self).contains("Could not find service") {
                let path = agentsDirectory.appendingPathComponent("\(label).plist").path
                statuses.append(HomebrewServiceStatus(name: name,
                    state: FileManager.default.fileExists(atPath: path) ? .stopped : .notRegistered, pid: nil))
            } else if output.exitCode == 0 {
                statuses.append(try Self.parse(output.standardOutput, name: name))
            } else {
                throw output.failure
            }
        }
        return statuses
    }

    static func parse(_ data: Data, name: String) throws -> HomebrewServiceStatus {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let state = lines.first(where: { $0.hasPrefix("state = ") })?.dropFirst("state = ".count) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        if state == "waiting" {
            return HomebrewServiceStatus(name: name, state: .stopped, pid: nil)
        }
        guard state == "running",
              let pidText = lines.first(where: { $0.hasPrefix("pid = ") })?.dropFirst("pid = ".count),
              let pid = Int32(pidText), pid > 0 else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        return HomebrewServiceStatus(name: name, state: .running, pid: pid)
    }
}
