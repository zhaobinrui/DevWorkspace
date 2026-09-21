import SwiftUI

struct WorkspaceDashboardView: View {
    @Environment(\.appLanguage) private var language
    @Bindable var store: WorkspaceStore
    let refresh: @MainActor () async -> Void
    var addProject: @MainActor () -> Void = {}
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: DevSpaceSpacing.large) {
            HStack {
                Text("projects.title").font(.title2.bold())
                Spacer()
                Button(action: addProject) { Label("projects.add", systemImage: "plus") }
                    .disabled(store.isAddingProject || store.catalogLoadBlocked)
                    .accessibilityIdentifier("workspace.addProject")
                Button {
                    Task { await refresh() }
                } label: { Label("workspace.action.refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isRefreshing || store.project == nil)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("workspace.refresh")
            }

            if let issue = store.projectIssue {
                Label(issue.localized(in: language), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if store.catalogLoadBlocked {
                    Button("projects.retry-load") { store.reloadCatalog() }
                }
            }
            if store.isAddingProject { ProgressView("projects.adding") }
            if let candidate = store.pendingRelocation {
                Text(candidate.rootDirectory.path).font(.caption).textSelection(.enabled)
                HStack {
                    Button("projects.confirm-move") { store.confirmRelocation() }
                    Button("projects.cancel") { store.cancelRelocation() }
                }
            }
            if let project = store.project {
                HStack {
                    Picker("projects.selected", selection: Binding(
                        get: { store.project?.id.rawValue ?? "" },
                        set: { if let id = ProjectIdentifier(rawValue: $0) { store.selectProject(id) } }
                    )) {
                        ForEach(store.catalog.projects) { project in Text(project.name).tag(project.id.rawValue) }
                    }.accessibilityIdentifier("workspace.projectPicker")
                    Button("projects.remove", role: .destructive) { confirmsRemoval = true }
                }
                Text(project.rootDirectory.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: DevSpaceSpacing.large) {
                        if store.currentSnapshot?.readings != nil {
                            let status = WorkspaceStatusPresentation(state: store.state, language: language)
                            DevSpaceStatusBadge(status: status.semanticStatus, title: status.title)
                            LocalWorkspaceReadingsView(store: store)
                        } else { WorkspaceSummaryView(state: store.state) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView {
                    Label("projects.empty", systemImage: "folder.badge.plus")
                } description: { Text("projects.empty-note") }
                actions: {
                    Button("projects.add", action: addProject).disabled(store.isAddingProject || store.catalogLoadBlocked)
                }
            }
        }
        .padding(DevSpaceSpacing.xLarge)
        .frame(minWidth: DevSpaceLayout.dashboardMinimumWidth, minHeight: DevSpaceLayout.dashboardMinimumHeight)
        .confirmationDialog("projects.remove-confirm", isPresented: $confirmsRemoval) {
            Button("projects.remove", role: .destructive) { store.removeSelectedProject() }
            Button("projects.cancel", role: .cancel) {}
        } message: { Text("projects.remove-note") }
        .task(id: store.project) {
            if store.shouldLoad { await refresh() }
        }
    }
}
