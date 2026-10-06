import AppKit

@MainActor
protocol ProjectApplicationLocating {
    func editor(_ kind: CommonProjectEditor) -> ProjectEditor?
}

@MainActor
struct InstalledProjectApplications: ProjectApplicationLocating {
    func editor(_ kind: CommonProjectEditor) -> ProjectEditor? {
        for identifier in kind.bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
                  Bundle(url: url)?.bundleIdentifier == identifier else { continue }
            return ProjectEditor(bundleIdentifier: identifier, applicationURL: url,
                                 name: url.deletingPathExtension().lastPathComponent)
        }
        return nil
    }

    static func icon(for url: URL?) -> NSImage? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func icon(bundleIdentifier: String) -> NSImage? {
        icon(for: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier))
    }
}
