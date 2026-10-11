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
            guard Set(catalog.preferences.map(\.projectID)).count == catalog.preferences.count,
                  catalog.preferences.allSatisfy({ preference in
                      catalog.projects.contains { $0.id == preference.projectID }
                      && (preference.editor == nil || preference.editor?.applicationURL.isFileURL == true)
                      && Set(preference.links.map(\.id)).count == preference.links.count
                      && preference.links.allSatisfy { ProjectURLPolicy.validated($0.url.absoluteString) != nil }
                      && (preference.profile?.isValid() ?? true)
                  }) else { throw LocalReadFailure(kind: .corruptStorage) }
            guard Set(catalog.managedProcesses.map(\.projectID)).count == catalog.managedProcesses.count,
                  catalog.managedProcesses.allSatisfy({ record in
                      catalog.projects.contains { project in
                          project.id == record.projectID
                            && project.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
                              == record.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
                      }
                      && ProjectProfile.validScriptName(record.scriptName)
                      && record.identity.pid > 0 && record.identity.executablePath.hasPrefix("/")
                  }) else { throw LocalReadFailure(kind: .corruptStorage) }
            guard Set(catalog.managedComposeRuns.map(\.projectID)).count == catalog.managedComposeRuns.count,
                  catalog.managedComposeRuns.allSatisfy({ run in
                      catalog.projects.contains { project in
                          project.id == run.projectID
                            && project.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
                              == run.rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
                      }
                      && ProjectProfile.validComposeName(run.configurationName)
                      && run.configurationDigest.count == 64
                      && !run.containerIDs.isEmpty
                      && Set(run.containerIDs).count == run.containerIDs.count
                      && run.containerIDs.allSatisfy { id in id.count == 64 && id.utf8.allSatisfy { byte in
                          (48...57).contains(byte) || (97...102).contains(byte)
                      } }
                  }) else { throw LocalReadFailure(kind: .corruptStorage) }
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
