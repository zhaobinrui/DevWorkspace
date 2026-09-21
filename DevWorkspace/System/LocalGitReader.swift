import Foundation
import Darwin

protocol ProjectRootResolving: Sendable {
    func project(at directory: URL) async throws -> ProjectReference
}

struct LocalGitClient: Sendable {
    let runner: any LocalCommandRunning

    func run(at directory: URL, arguments: [String]) async throws -> LocalCommandOutput {
        try await runner.run(LocalCommand(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: [
                "--no-optional-locks", "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false",
                "-c", "core.quotePath=false", "-c", "submodule.recurse=false",
            ] + arguments,
            directory: directory
        ))
    }

    static func validateDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw LocalReadFailure(kind: .invalidDirectory) }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw LocalReadFailure(kind: .invalidDirectory) }
        } catch let failure as LocalReadFailure { throw failure }
        catch {
            let failure = LocalReadFailure.classify(error)
            throw failure.kind == .permissionDenied ? failure : LocalReadFailure(kind: .invalidDirectory)
        }
        guard access(canonical.path, R_OK | X_OK) == 0 else { throw LocalReadFailure(kind: .permissionDenied) }
        return canonical
    }

    static func hasGitAncestor(_ directory: URL) throws -> Bool {
        var current = directory
        while true {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: current.appendingPathComponent(".git").path)
                return true
            } catch {
                let ns = error as NSError
                if ns.domain != NSCocoaErrorDomain || ![NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(ns.code) {
                    // Missing metadata is a normal non-Git folder; inaccessible metadata is a failed read.
                    if LocalReadFailure.classify(error).kind == .permissionDenied { throw LocalReadFailure(kind: .permissionDenied) }
                    if ns.domain != NSPOSIXErrorDomain || ns.code != ENOENT { throw LocalReadFailure.classify(error) }
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
    }
}

struct LocalProjectRootResolver: ProjectRootResolving {
    var runner: any LocalCommandRunning = ReadOnlyCommandRunner()

    func project(at directory: URL) async throws -> ProjectReference {
        var root = try LocalGitClient.validateDirectory(directory)
        if try LocalGitClient.hasGitAncestor(root) {
            let output = try await LocalGitClient(runner: runner).run(at: root, arguments: ["rev-parse", "--show-toplevel"])
            try output.requireSuccess()
            guard var path = String(data: output.standardOutput, encoding: .utf8), path.hasSuffix("\n") else {
                throw LocalReadFailure(kind: .invalidOutput)
            }
            // Remove just Git's delimiter; spaces and newlines can be part of a valid directory name.
            path.removeLast()
            guard path.hasPrefix("/") else { throw LocalReadFailure(kind: .invalidOutput) }
            root = try LocalGitClient.validateDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
        try Task.checkCancellation()
        return ProjectReference(identity: try LocalProjectIdentityResolver().resolve(rootDirectory: root), name: root.lastPathComponent)
    }
}

struct LocalGitStatusReader: GitStatusReading {
    var runner: any LocalCommandRunning = ReadOnlyCommandRunner()

    func status(for project: ProjectReference) async throws -> GitSummary? {
        let root = try LocalGitClient.validateDirectory(project.rootDirectory)
        guard try LocalGitClient.hasGitAncestor(root) else { return nil }
        let client = LocalGitClient(runner: runner)
        let filters = try await client.run(at: root, arguments: ["config", "--name-only", "--null", "--get-regexp", "^filter\\..*\\.(clean|smudge|process|required)$"])
        guard filters.exitCode == 0 || (filters.exitCode == 1 && filters.standardOutput.isEmpty && filters.standardError.isEmpty) else {
            throw filters.failure
        }
        var overrides: [String] = []
        let keys = String(decoding: filters.standardOutput, as: UTF8.self).split(separator: "\0")
        let drivers = Set(keys.compactMap { key -> String? in
            guard let dot = key.lastIndex(of: ".") else { return nil }
            return String(key[..<dot])
        })
        // Even read-only status may run clean/process filters while checking files. Override every configured
        // driver, as well as fsmonitor/hooks, before examining an untrusted repository. Never invoke its commands.
        for driver in drivers.sorted() {
            for option in ["clean=", "smudge=", "process=", "required=false"] {
                overrides += ["-c", "\(driver).\(option)"]
            }
        }
        let output = try await client.run(at: root, arguments: overrides + [
            "status", "--porcelain=v2", "--branch", "--untracked-files=all", "--ignore-submodules=all", "-z",
        ])
        try output.requireSuccess()
        return try GitStatusParser.parse(output.standardOutput)
    }
}

enum GitStatusParser {
    static func parse(_ data: Data) throws -> GitSummary {
        guard data.last == 0 else { throw LocalReadFailure(kind: .invalidOutput) }
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var branch: String?
        var oid: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var hasDivergence = false
        var changed = 0
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.head ") { branch = String(record.dropFirst(14)) }
            else if record.hasPrefix("# branch.oid ") { oid = String(record.dropFirst(13)) }
            else if record.hasPrefix("# branch.upstream ") { upstream = String(record.dropFirst(18)) }
            else if record.hasPrefix("# branch.ab ") {
                let counts = record.dropFirst(12).split(separator: " ")
                guard counts.count == 2, counts[0].first == "+", counts[1].first == "-",
                      let a = Int(counts[0].dropFirst()), let b = Int(counts[1].dropFirst()), a >= 0, b >= 0 else {
                    throw LocalReadFailure(kind: .invalidOutput)
                }
                ahead = a; behind = b
                hasDivergence = true
            } else if record.hasPrefix("# ") {
                // Porcelain v2 explicitly permits unknown header extensions.
            } else if record.hasPrefix("? ") || record.hasPrefix("! ") {
                guard record.count > 2 else { throw LocalReadFailure(kind: .invalidOutput) }
                if record.first == "?" { changed += 1 }
            } else if let type = record.first, ["1", "2", "u"].contains(String(type)) {
                let fieldCount = type == "1" ? 9 : (type == "2" ? 10 : 11)
                guard record.split(separator: " ", maxSplits: fieldCount - 1, omittingEmptySubsequences: false).count == fieldCount else {
                    throw LocalReadFailure(kind: .invalidOutput)
                }
                changed += 1
                if type == "2" {
                    // A rename has a second NUL-delimited path; it is not another changed file.
                    index += 1
                    guard index < records.count else { throw LocalReadFailure(kind: .invalidOutput) }
                }
            } else { throw LocalReadFailure(kind: .invalidOutput) }
            index += 1
        }
        guard let branch, !branch.isEmpty, let oid, !oid.isEmpty else { throw LocalReadFailure(kind: .invalidOutput) }
        return GitSummary(
            branch: branch == "(detached)" ? String(oid.prefix(8)) : branch,
            changedFileCount: changed, commitsAhead: ahead, commitsBehind: behind,
            upstream: upstream, isDetached: branch == "(detached)", isUnborn: oid == "(initial)",
            hasDivergence: hasDivergence
        )
    }
}
