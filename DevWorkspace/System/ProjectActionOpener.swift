import AppKit
import UniformTypeIdentifiers

@MainActor
protocol ProjectActionOpening {
    func chooseEditor() async throws -> ProjectEditor?
    func openProject(_ root: URL, editor: ProjectEditor) async throws
    func openTerminal(_ root: URL) async throws
    func openFolder(_ root: URL) throws
    func revealConfiguration(_ name: String, root: URL) throws
    func openLink(_ url: URL) throws
    func copy(_ text: String) throws
}

@MainActor
struct SystemProjectActionOpener: ProjectActionOpening {
    func chooseEditor() async throws -> ProjectEditor? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        // Selecting an application establishes per-project trust; repositories cannot select executables.
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK else { return nil }
        guard let url = panel.url, let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else { throw ProjectActionFailure.missingApplication }
        return ProjectEditor(bundleIdentifier: identifier, applicationURL: url,
                             name: url.deletingPathExtension().lastPathComponent)
    }

    func openProject(_ root: URL, editor: ProjectEditor) async throws {
        try validateRoot(root)
        let saved = editor.applicationURL
        let application: URL?
        if Bundle(url: saved)?.bundleIdentifier == editor.bundleIdentifier {
            application = saved
        } else {
            application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier)
        }
        guard let application else { throw ProjectActionFailure.missingApplication }
        try await launch(root, application: application)
    }

    func openTerminal(_ root: URL) async throws {
        try validateRoot(root)
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ProjectActionFailure.missingApplication
        }
        // Terminal accepts a directory URL; no AppleScript or interpolated shell command is necessary.
        try await launch(root, application: application)
    }

    private func launch(_ root: URL, application: URL) async throws {
        do {
            _ = try await NSWorkspace.shared.open([root], withApplicationAt: application,
                                                 configuration: NSWorkspace.OpenConfiguration())
        } catch { throw ProjectActionFailure.openFailed }
    }

    func openFolder(_ root: URL) throws {
        try validateRoot(root)
        guard NSWorkspace.shared.open(root) else { throw ProjectActionFailure.openFailed }
    }

    func revealConfiguration(_ name: String, root: URL) throws {
        try validateRoot(root)
        guard LocalProjectConfigurationReader.dockerNames.contains(name) else { throw ProjectActionFailure.openFailed }
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isReadableFile(atPath: file.path) else { throw LocalReadFailure(kind: .unavailable) }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func openLink(_ url: URL) throws {
        guard let safe = ProjectURLPolicy.validated(url.absoluteString) else { throw ProjectActionFailure.invalidURL }
        guard NSWorkspace.shared.open(safe) else { throw ProjectActionFailure.openFailed }
    }

    func copy(_ text: String) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw ProjectActionFailure.clipboardFailed }
    }

    private func validateRoot(_ root: URL) throws {
        guard root.isFileURL, try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LocalReadFailure(kind: .invalidDirectory)
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else { throw LocalReadFailure(kind: .permissionDenied) }
    }
}
