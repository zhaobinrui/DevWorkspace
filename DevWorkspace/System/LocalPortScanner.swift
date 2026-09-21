import Darwin
import Foundation

struct InspectedProcess: Sendable {
    let identity: ProcessIdentity
    let workingDirectory: URL?
    let directoryFailure: LocalReadFailure?
}

protocol ProcessInspecting: Sendable {
    func inspect(pid: Int32) throws -> InspectedProcess
}

struct NativeProcessInspector: ProcessInspecting {
    func inspect(pid: Int32) throws -> InspectedProcess {
        let before = try identity(pid: pid)
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.stride
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size))
        let directory: URL?
        let failure: LocalReadFailure?
        if result == size {
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            directory = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath() : nil
            failure = directory == nil ? LocalReadFailure(kind: .unavailable) : nil
        } else {
            directory = nil
            failure = LocalReadFailure(kind: errno == EACCES || errno == EPERM ? .permissionDenied : .unavailable)
        }
        let after = try identity(pid: pid)
        guard before == after else { throw LocalReadFailure(kind: .processChanged) }
        return InspectedProcess(identity: before, workingDirectory: directory, directoryFailure: failure)
    }

    private func identity(pid: Int32) throws -> ProcessIdentity {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { throw systemFailure() }
        // The SDK's PROC_PIDPATHINFO_MAXSIZE macro is 4 * MAXPATHLEN and is not imported into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { throw systemFailure() }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        guard path.hasPrefix("/") else { throw LocalReadFailure(kind: .invalidOutput) }
        return ProcessIdentity(pid: pid, userID: info.pbi_uid, executablePath: path,
                               startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    private func systemFailure() -> LocalReadFailure {
        LocalReadFailure(kind: errno == ESRCH ? .processChanged : (errno == EACCES || errno == EPERM ? .permissionDenied : .unavailable))
    }
}

struct SocketProcessRecord: Equatable, Sendable {
    let pid: Int32
    let userID: UInt32
    let name: String
    var sockets: [ListeningSocket]
}

enum LsofSocketParser {
    static func parse(_ data: Data) throws -> [SocketProcessRecord] {
        if data.isEmpty { return [] }
        guard data.last == 0 || (data.last == 10 && data.dropLast().last == 0) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        var records: [SocketProcessRecord] = []
        var pid: Int32?
        var uid: UInt32?
        var name: String?
        var transport: SocketTransport?
        var hasDescriptor = false
        var hasEndpoint = false
        var sockets: [ListeningSocket] = []

        func finishSocket() throws {
            // A truncated descriptor must not become a successful empty scan.
            if hasDescriptor && (transport == nil || !hasEndpoint) { throw LocalReadFailure(kind: .invalidOutput) }
        }

        func finish() throws {
            try finishSocket()
            guard let pid else { return }
            guard let uid, let name else { throw LocalReadFailure(kind: .invalidOutput) }
            records.append(SocketProcessRecord(pid: pid, userID: uid, name: name, sockets: sockets))
        }

        for raw in data.split(separator: 0) {
            let field = String(decoding: raw.drop(while: { $0 == 10 }), as: UTF8.self)
            guard let tag = field.first else { continue }
            let value = String(field.dropFirst())
            switch tag {
            case "p":
                try finish()
                guard let number = Int32(value), number > 0 else { throw LocalReadFailure(kind: .invalidOutput) }
                pid = number; uid = nil; name = nil; transport = nil; hasDescriptor = false; hasEndpoint = false; sockets = []
            case "c": name = value
            case "u":
                guard let number = UInt32(value) else { throw LocalReadFailure(kind: .invalidOutput) }
                uid = number
            case "f":
                try finishSocket()
                guard pid != nil else { throw LocalReadFailure(kind: .invalidOutput) }
                hasDescriptor = true; hasEndpoint = false; transport = nil
            case "P":
                guard hasDescriptor, let parsed = SocketTransport(rawValue: value) else { throw LocalReadFailure(kind: .invalidOutput) }
                transport = parsed
            case "n":
                guard pid != nil, hasDescriptor, !hasEndpoint, let transport else { throw LocalReadFailure(kind: .invalidOutput) }
                hasEndpoint = true
                // Connected UDP sockets are client traffic, not listening/bound server endpoints.
                if transport == .udp && (value.contains("->") || value.hasSuffix(":*")) { continue }
                guard !value.contains("->"), let separator = value.lastIndex(of: ":"),
                      separator != value.startIndex,
                      let port = UInt16(value[value.index(after: separator)...]), port > 0 else {
                    throw LocalReadFailure(kind: .invalidOutput)
                }
                sockets.append(ListeningSocket(transport: transport, address: String(value[..<separator]), port: port))
            default:
                // lsof may add fields; the selected process/socket identity fields remain mandatory.
                continue
            }
        }
        try finish()
        guard !records.isEmpty else { throw LocalReadFailure(kind: .invalidOutput) }
        return records
    }
}

protocol LocalPortScanning: Sendable {
    func scan() async throws -> [ListeningProcess]
}

struct LocalPortScanner: LocalPortScanning {
    var runner: any LocalCommandRunning = ReadOnlyCommandRunner()
    var inspector: any ProcessInspecting = NativeProcessInspector()
    var userID: UInt32 = getuid()

    func scan() async throws -> [ListeningProcess] {
        // Process churn is normal. Retry once, but do not report a trustworthy empty list after repeated identity changes.
        do { return try await scanOnce() }
        catch let error as LocalReadFailure where error.kind == .processChanged {
            try Task.checkCancellation()
            return try await scanOnce()
        }
    }

    private func scanOnce() async throws -> [ListeningProcess] {
        let beganAt = Date().timeIntervalSince1970
        var records: [Int32: SocketProcessRecord] = [:]
        for transport in [SocketTransport.tcp, .udp] {
            var arguments = ["-nP", "-a", "-u", String(userID), "-i\(transport.rawValue)"]
            if transport == .tcp { arguments.append("-sTCP:LISTEN") }
            arguments.append("-F0pcufPn")
            let output = try await runner.run(LocalCommand(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: arguments))
            // lsof uses exit 1 for no matches. A diagnostic or non-empty failed output is not an empty result.
            if output.exitCode == 1 && output.standardOutput.isEmpty && output.standardError.isEmpty { continue }
            try output.requireSuccess()
            guard output.standardError.isEmpty else { throw output.failure }
            for record in try LsofSocketParser.parse(output.standardOutput) {
                guard record.userID == userID else { throw LocalReadFailure(kind: .invalidOutput) }
                if var existing = records[record.pid] {
                    guard existing.userID == record.userID, existing.name == record.name else { throw LocalReadFailure(kind: .processChanged) }
                    existing.sockets += record.sockets
                    records[record.pid] = existing
                } else { records[record.pid] = record }
            }
        }
        var processes: [ListeningProcess] = []
        for record in records.values.sorted(by: { $0.pid < $1.pid }) where !record.sockets.isEmpty {
            try Task.checkCancellation()
            let inspected = try inspector.inspect(pid: record.pid)
            let start = Double(inspected.identity.startedSeconds) + Double(inspected.identity.startedMicroseconds) / 1_000_000
            guard inspected.identity.userID == userID, start <= beganAt else { throw LocalReadFailure(kind: .processChanged) }
            processes.append(ListeningProcess(
                identity: inspected.identity, name: record.name,
                userName: NSUserName(), workingDirectory: inspected.workingDirectory,
                directoryFailure: inspected.directoryFailure,
                sockets: Array(Set(record.sockets)).sorted { ($0.port, $0.transport.rawValue, $0.address) < ($1.port, $1.transport.rawValue, $1.address) }
            ))
        }
        return processes
    }
}
