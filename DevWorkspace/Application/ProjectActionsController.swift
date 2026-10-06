import Foundation
import Observation

@MainActor @Observable
final class ProjectActionsController {
    private(set) var isBusy = false
    private(set) var feedbackKey: String?
    private(set) var failure: LocalReadFailure?
    private let opener: any ProjectActionOpening
    private let applications: any ProjectApplicationLocating
    private(set) var installedEditors: [CommonProjectEditor: ProjectEditor] = [:]

    init(opener: any ProjectActionOpening = SystemProjectActionOpener(),
         applications: any ProjectApplicationLocating = InstalledProjectApplications()) {
        self.opener = opener
        self.applications = applications
    }

    func reloadApplications() {
        installedEditors = Dictionary(uniqueKeysWithValues: CommonProjectEditor.allCases.compactMap { kind in
            applications.editor(kind).map { (kind, $0) }
        })
    }

    func openCommonEditor(_ kind: CommonProjectEditor, project: ProjectReference, store: WorkspaceStore) async {
        guard !isBusy else { return }
        // Resolve again at activation: an application can disappear after the tile was rendered.
        guard let choice = applications.editor(kind) else {
            clearFeedback(); feedbackKey = "actions.error.missingApplication"; reloadApplications(); return
        }
        await editor(project: project, store: store, selectedEditor: choice)
    }

    func clearFeedback() { feedbackKey = nil; failure = nil }

    func perform(_ operation: () throws -> Void) {
        clearFeedback()
        do { try operation() }
        catch { report(error) }
    }

    func copy(_ value: String) {
        perform { try opener.copy(value); feedbackKey = "actions.copied" }
    }

    func folder(_ root: URL) { perform { try opener.openFolder(root) } }
    func reveal(_ name: String, root: URL) { perform { try opener.revealConfiguration(name, root: root) } }
    func open(_ url: URL) { perform { try opener.openLink(url) } }

    func terminal(_ root: URL) async {
        guard !isBusy else { return }
        isBusy = true; clearFeedback()
        defer { isBusy = false }
        do { try await opener.openTerminal(root) } catch { report(error) }
    }

    func editor(project: ProjectReference, store: WorkspaceStore, change: Bool = false, selectedEditor: ProjectEditor? = nil) async {
        guard !isBusy else { return }
        isBusy = true; clearFeedback()
        defer { isBusy = false }
        do {
            var choice = store.preferences(for: project.id).editor
            if choice == nil || change || selectedEditor != nil {
                let selected: ProjectEditor
                if let selectedEditor { selected = selectedEditor }
                else {
                    guard let picked = try await opener.chooseEditor() else { return }
                    selected = picked
                }
                // A picker can outlive a selection change. Bind to the captured identity and never
                // overwrite links edited while the panel was open or resurrect a removed project.
                guard store.catalog.projects.contains(project) else { throw LocalReadFailure(kind: .invalidDirectory) }
                var preferences = store.preferences(for: project.id)
                preferences.editor = selected
                try store.savePreferences(preferences)
                choice = selected
            }
            guard let choice, store.catalog.projects.contains(project) else { return }
            try await opener.openProject(project.rootDirectory, editor: choice)
        } catch { report(error) }
    }

    private func report(_ error: any Error) {
        if let action = error as? ProjectActionFailure { feedbackKey = "actions.error." + action.rawValue }
        else { failure = .classify(error) }
    }
}
