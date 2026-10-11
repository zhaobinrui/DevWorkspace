import SwiftUI

struct WorkspaceDashboardView: View {
    @Environment(\.appLanguage) private var language
    @Bindable var store: WorkspaceStore
    let refresh: @MainActor () async -> Void
    var addProject: @MainActor () -> Void = {}
    @State private var confirmsRemoval = false
    @State private var showsUserProcesses = false

    init(store: WorkspaceStore, refresh: @escaping @MainActor () async -> Void,
         addProject: @escaping @MainActor () -> Void = {}, showUserProcesses: Bool = false) {
        self.store = store
        self.refresh = refresh
        self.addProject = addProject
        _showsUserProcesses = State(initialValue: showUserProcesses)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
                .frame(maxHeight: .infinity)
                .background(.quaternary.opacity(0.35))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header.padding(24)
                Divider().padding(.horizontal, 24)
                WorkspaceScrollRegion {
                    VStack(alignment: .leading, spacing: 20) {
                        projectFeedback
                        if showsUserProcesses {
                            WorkspaceOverviewView(store: store, showsUserProcesses: true)
                        } else if store.project != nil {
                            ProjectActionsView(store: store)
                            if store.currentSnapshot?.readings != nil || store.userProcesses != nil {
                                WorkspaceOverviewView(store: store)
                            } else {
                                WorkspaceSummaryView(state: store.presentationState)
                            }
                        } else {
                            ContentUnavailableView {
                                Label("projects.empty", systemImage: "folder.badge.plus")
                            } description: { Text("projects.empty-note") }
                            actions: {
                                Button("projects.add", action: addProject)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.isAddingProject || store.catalogLoadBlocked)
                            }
                            .frame(maxWidth: .infinity, minHeight: 340)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(showsUserProcesses ? "user-processes" : store.project?.id.rawValue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.background)
        .accentColor(DevSpaceColor.workspaceAccent)
        .frame(minWidth: DevSpaceLayout.dashboardMinimumWidth, minHeight: DevSpaceLayout.dashboardMinimumHeight)
        .confirmationDialog("projects.remove-confirm", isPresented: $confirmsRemoval) {
            Button("projects.remove", role: .destructive) { store.removeSelectedProject() }
            Button("projects.cancel", role: .cancel) {}
        } message: { Text("projects.remove-note") }
        .task(id: store.project) {
            if store.shouldLoad { await store.refresh(forceProcessRefresh: false) }
        }
        .task(id: showsUserProcesses) {
            if showsUserProcesses { await store.refreshUserProcesses(force: false) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("DevWorkspace").font(.system(size: 13, weight: .semibold))
                    Text("dashboard.local-workspace").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 24)

            Button { showsUserProcesses = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                    Text("processes.title").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    if let count = store.userProcesses?.value?.count {
                        Text(count, format: .number).font(.caption.monospacedDigit())
                    }
                }
                .padding(10)
                .background(showsUserProcesses ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 10)
            .accessibilityIdentifier("workspace.userProcesses")
            .accessibilityAddTraits(showsUserProcesses ? .isSelected : [])

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("projects.title").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(store.catalog.projects.count, format: .number).font(.caption.monospacedDigit())
                }.foregroundStyle(.secondary).padding(.horizontal, 20)
                WorkspaceScrollRegion {
                    VStack(spacing: 5) {
                        ForEach(store.catalog.projects) { project in
                            projectRow(project)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                Button(action: addProject) {
                    Label("projects.add", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9).padding(.horizontal, 10)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isAddingProject || store.catalogLoadBlocked)
                .accessibilityIdentifier("workspace.addProject")
                Label("dashboard.local-only", systemImage: "lock.shield")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16)
        }
    }

    private func projectRow(_ project: ProjectReference) -> some View {
        let selected = !showsUserProcesses && store.project?.id == project.id
        return Button { showsUserProcesses = false; store.selectProject(project.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                    Text(project.rootDirectory.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3, height: 20)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.catalogLoadBlocked)
        .help(project.rootDirectory.path)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("workspace.project.\(project.id.rawValue)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("dashboard.overview").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if store.project != nil || showsUserProcesses {
                    Button { Task {
                        if showsUserProcesses { await store.refreshUserProcesses() }
                        else { await refresh() }
                    } } label: {
                        Label("workspace.action.refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.regular)
                    .disabled(showsUserProcesses ? store.isRefreshingUserProcesses : store.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("workspace.refresh")
                    if !showsUserProcesses {
                        WorkspaceOverflowMenu(title: "dashboard.manage") {
                            Button("projects.remove", role: .destructive) { confirmsRemoval = true }
                                .disabled(store.catalogLoadBlocked)
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(showsUserProcesses ? language.localized("processes.title") : store.project?.name ?? "DevWorkspace")
                    .font(.system(size: 26, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if store.project != nil && !showsUserProcesses {
                    let status = WorkspaceStatusPresentation(state: store.presentationState, language: language)
                    Label(status.title, systemImage: status.semanticStatus.token.systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(status.semanticStatus.token.color)
                        .fixedSize()
                }
            }
            if showsUserProcesses {
                Text("processes.scope").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let project = store.project {
                Label(project.rootDirectory.path, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(project.rootDirectory.path)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var projectFeedback: some View {
        if let issue = store.projectIssue {
            VStack(alignment: .leading, spacing: 10) {
                Label(issue.localized(in: language), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if store.catalogLoadBlocked {
                    Button("projects.retry-load") { store.reloadCatalog() }
                }
                if let candidate = store.pendingRelocation {
                    Text(candidate.rootDirectory.path).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("projects.confirm-move") { store.confirmRelocation() }
                        Button("projects.cancel") { store.cancelRelocation() }
                    }
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        if store.isAddingProject { ProgressView("projects.adding") }
    }
}

// NSScrollView-backed content is absent from ImageRenderer output. Visual fixtures use the same
// layout without native scrolling; runtime always keeps scrolling and keyboard navigation enabled.
private struct WorkspaceStaticRenderingKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var workspaceStaticRendering: Bool {
        get { self[WorkspaceStaticRenderingKey.self] }
        set { self[WorkspaceStaticRenderingKey.self] = newValue }
    }
}
struct WorkspaceScrollRegion<Content: View>: View {
    @Environment(\.workspaceStaticRendering) private var staticRendering
    @ViewBuilder let content: Content
    var body: some View {
        if staticRendering {
            GeometryReader { geometry in
                content.frame(width: geometry.size.width, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }.clipped()
        } else {
            ScrollView { content }
        }
    }
}

struct WorkspaceOverflowMenu<Content: View>: View {
    @Environment(\.workspaceStaticRendering) private var staticRendering
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    private var label: some View { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
    var body: some View {
        Group {
            if staticRendering {
                // ImageRenderer cannot draw NSPopUpButton. Capture its label only, not a simulated open menu.
                label
            } else {
                Menu { content } label: { label }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }.accessibilityLabel(Text(title)).help(Text(title))
    }
}
