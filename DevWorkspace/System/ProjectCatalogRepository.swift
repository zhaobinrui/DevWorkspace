import Foundation

protocol ProjectCatalogPersisting: Sendable {
    func load() throws -> ProjectCatalog
    func save(_ catalog: ProjectCatalog) throws
}

struct FileProjectCatalogRepository: ProjectCatalogPersisting {
    let fileURL: URL

    static var applicationDefault: Self {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevSpaceProduct.workspace.bundleIdentifier, isDirectory: true)
        return Self(fileURL: directory.appendingPathComponent("projects-v1.json"))
    }

    func load() throws -> ProjectCatalog {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return ProjectCatalog() }
            throw LocalReadFailure.classify(error)
        }
        do {
            let catalog = try JSONDecoder().decode(ProjectCatalog.self, from: data)
            guard catalog.version == 1 else { throw LocalReadFailure(kind: .unsupportedVersion) }
            guard Set(catalog.projects.map(\.id)).count == catalog.projects.count,
                  catalog.projects.allSatisfy({ $0.rootDirectory.isFileURL }),
                  catalog.selectedID == nil || catalog.projects.contains(where: { $0.id == catalog.selectedID }),
                  catalog.bindings.allSatisfy({ binding in binding.projectID == nil || catalog.projects.contains(where: { $0.id == binding.projectID }) }) else {
                throw LocalReadFailure(kind: .corruptStorage)
            }
            return catalog
        } catch let failure as LocalReadFailure { throw failure }
        catch { throw LocalReadFailure(kind: .corruptStorage) }
    }

    func save(_ catalog: ProjectCatalog) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(catalog)
            // Atomic replacement prevents a crash during save from destroying the previous selection.
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { throw LocalReadFailure.classify(error) }
    }
}
