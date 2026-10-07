import Foundation
import Darwin
import CryptoKit

struct LocalProjectConfigurationReader: ProjectConfigurationReading {
    static let dockerNames = ["Dockerfile", "dockerfile", "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let configurationNames = ["package.json", "application.properties", "application.yml", "application.yaml",
        "src/main/resources/application.properties", "src/main/resources/application.yml", "src/main/resources/application.yaml"]
    private static let moduleDescriptors = ["pom.xml", "build.gradle", "build.gradle.kts"]
    private static let moduleConfigurations = ["src/main/resources/application.properties",
        "src/main/resources/application.yml", "src/main/resources/application.yaml"]
    // Directory listing is bounded because an untrusted checkout may contain enormous generated trees.
    private static let maximumRootEntries = 512

    func read(root: URL) async throws -> ProjectDiscovery {
        let worker = Task.detached(priority: .utility) { try Self.scan(root: root) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func scan(root: URL) throws -> ProjectDiscovery {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonical.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw LocalReadFailure(kind: .invalidDirectory) }
        guard access(canonical.path, R_OK | X_OK) == 0 else { throw LocalReadFailure(kind: .permissionDenied) }
        var result = ProjectDiscovery()
        var dockerIdentities = Set<String>()
        var names = dockerNames + configurationNames
        do {
            names += try directModuleConfigurationNames(root: canonical, issues: &result.issues)
        } catch is CancellationError { throw CancellationError() }
        catch { result.issues.append(ConfigurationIssue(source: "modules", failure: .classify(error))) }
        for name in names {
            try Task.checkCancellation()
            do {
                guard let file = try readFile(name, root: canonical, content: !dockerNames.contains(name)) else { continue }
                if dockerNames.contains(name) {
                    // APFS is usually case-insensitive; Dockerfile and dockerfile may be the same inode.
                    if dockerIdentities.insert(file.identity).inserted { result.dockerFiles.append(name) }
                    continue
                }
                let parsed = try parse(data: file.data, source: name)
                result.links += parsed.links
                result.packageScripts += parsed.packageScripts
                if let digest = parsed.packageDigest { result.packageDigest = digest }
                result.issues += parsed.issues
            } catch is CancellationError { throw CancellationError() }
            catch { result.issues.append(ConfigurationIssue(source: name, failure: .classify(error))) }
        }
        return result
    }

    private static func directModuleConfigurationNames(root: URL, issues: inout [ConfigurationIssue]) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        guard entries.count <= maximumRootEntries else { throw LocalReadFailure(kind: .outputLimit) }
        var names: [String] = []
        for entry in entries where !entry.hasPrefix(".") {
            try Task.checkCancellation()
            var isModule = false
            for descriptor in moduleDescriptors {
                let path = "\(entry)/\(descriptor)"
                do {
                    if try readFile(path, root: root, content: false) != nil { isModule = true; break }
                } catch {
                    issues.append(ConfigurationIssue(source: path, failure: .classify(error)))
                }
            }
            if isModule {
                // Only direct build modules are considered; arbitrary nested trees and profile
                // overlays could present unrelated or environment-dependent URLs as current.
                names += moduleConfigurations.map { "\(entry)/\($0)" }
            }
        }
        return names
    }

    private static func readFile(_ name: String, root: URL, content: Bool) throws -> (data: Data, identity: String)? {
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        // Nonblocking open plus fstat rejects FIFOs/devices; a hostile repository must not hang a refresh.
        // Walk from an already opened root, refusing intermediate and final symlinks without
        // resolving the path first; otherwise a symlink swap could escape the chosen project.
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalReadFailure(kind: .permissionDenied) }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let code = errno
                if code == ENOENT { return nil }
                if code == ENOTDIR {
                    var item = stat()
                    if fstatat(parent, component, &item, AT_SYMLINK_NOFOLLOW) == 0,
                       (item.st_mode & S_IFMT) == S_IFLNK {
                        throw LocalReadFailure(kind: .permissionDenied)
                    }
                    return nil
                }
                throw LocalReadFailure(kind: [EACCES, EPERM, ELOOP].contains(code) ? .permissionDenied : .unavailable)
            }
            close(parent); parent = next
        }
        guard let last = components.last else { throw LocalReadFailure(kind: .invalidOutput) }
        let fd = openat(parent, last, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw LocalReadFailure(kind: [EACCES, EPERM, ELOOP].contains(errno) ? .permissionDenied : .unavailable)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        let identity = "\(info.st_dev):\(info.st_ino)"
        guard content else { return (Data(), identity) }
        guard info.st_size <= 262_144 else { throw LocalReadFailure(kind: .outputLimit) }
        var bytes = [UInt8](repeating: 0, count: 262_145)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw LocalReadFailure(kind: .unavailable) }
        guard count <= 262_144 else { throw LocalReadFailure(kind: .outputLimit) }
        return (Data(bytes.prefix(count)), identity)
    }

    static func parse(data: Data, source: String) throws -> ProjectDiscovery {
        var result = ProjectDiscovery()
        func append(_ name: String, _ value: String, _ key: String) {
            guard let url = ProjectURLPolicy.validated(value) else {
                result.issues.append(ConfigurationIssue(source: source + " · " + key, failure: LocalReadFailure(kind: .invalidOutput)))
                return
            }
            result.links.append(DiscoveredProjectLink(name: name, url: url, source: source + " · " + key))
        }
        if source == "package.json" {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any] else {
                throw LocalReadFailure(kind: .invalidOutput)
            }
            result.packageDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let scripts = json["scripts"] as? [String: String] ?? [:]
            for (name, body) in scripts.sorted(by: { $0.key < $1.key }) {
                // Script bodies are previewed in memory but never copied into project preferences.
                guard ProjectProfile.validScriptName(name), body.utf8.count <= 8_192,
                      !body.contains("\0") else {
                    result.issues.append(ConfigurationIssue(source: "package.json · scripts", failure: .init(kind: .invalidOutput)))
                    continue
                }
                result.packageScripts.append(DiscoveredPackageScript(name: name, body: body))
            }
            // Only literal port flags are hints; never evaluate scripts or infer HTTP from arbitrary processes.
            let expression = try NSRegularExpression(pattern: #"(?:^|\s)--port(?:=|\s+)([0-9]{1,5})(?=\s|$)"#)
            for (key, value) in scripts.sorted(by: { $0.key < $1.key }) {
                guard ["start", "dev", "serve"].contains(key) else { continue }
                guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                      let range = Range(match.range(at: 1), in: value), let port = UInt16(value[range]), port > 0 else {
                    if value.range(of: #"(?:^|\s)--port(?:=|\s+)"#, options: .regularExpression) != nil {
                        result.issues.append(ConfigurationIssue(source: source + " · scripts." + key, failure: .init(kind: .invalidOutput)))
                    }
                    continue
                }
                append(key, "http://localhost:\(port)", "scripts." + key)
            }
            // Recognize only explicit documentation/homepage fields, never arbitrary string contents.
            for key in ["homepage", "documentation"] {
                if let value = json[key] as? String, value.hasPrefix("http") { append(key, value, key) }
            }
            return result
        }
        guard let text = String(data: data, encoding: .utf8) else { throw LocalReadFailure(kind: .invalidOutput) }
        let properties = source.hasSuffix(".properties")
        var fields: [String: String] = [:]
        var stack: [(Int, String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") { continue }
            // Multi-document YAML/profile merging is not implemented: don't present a merged false endpoint.
            if !properties && (trimmed == "---" || line.contains("\t")) { throw LocalReadFailure(kind: .invalidOutput) }
            guard let separator = trimmed.firstIndex(of: properties ? "=" : ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            let indentation = line.prefix(while: { $0 == " " }).count
            if !properties {
                while let last = stack.last, last.0 >= indentation { stack.removeLast() }
                if value.isEmpty { stack.append((indentation, key)); continue }
            }
            if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            fields[(properties ? [] : stack.map(\.1)).appending(key).joined(separator: ".")] = value
        }
        if fields["spring.config.activate.on-profile"] != nil {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        if let ssl = fields["server.ssl.enabled"], !["true", "false"].contains(ssl) {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        let relevant = ["server.port", "server.servlet.context-path", "server.ssl.enabled", "springdoc.swagger-ui.path", "springdoc.api-docs.path", "springdoc.swagger-ui.url"]
        if relevant.contains(where: { fields[$0]?.contains("${") == true }) {
            throw LocalReadFailure(kind: .invalidOutput)
        }
        if let raw = fields["server.port"] {
            guard let port = UInt16(raw), port > 0 else { throw LocalReadFailure(kind: .invalidOutput) }
            let scheme = fields["server.ssl.enabled"] == "true" ? "https" : "http"
            let context = fields["server.servlet.context-path"] ?? ""
            guard context.isEmpty || context.hasPrefix("/") else { throw LocalReadFailure(kind: .invalidOutput) }
            let base = "\(scheme)://localhost:\(port)" + (context == "/" ? "" : context)
            append("Service", base, "server.port")
            for key in ["springdoc.swagger-ui.path", "springdoc.api-docs.path"] {
                if let path = fields[key], path.hasPrefix("/") { append("API docs", base + path, key) }
            }
        }
        if let value = fields["springdoc.swagger-ui.url"], value.hasPrefix("http") {
            append("API docs", value, "springdoc.swagger-ui.url")
        }
        return result
    }
}

private extension Array where Element == String {
    func appending(_ item: String) -> [String] { self + [item] }
}
