import SwiftUI
import AppKit

struct ProjectActionsView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.workspaceStaticRendering) private var staticRendering
    @Bindable var store: WorkspaceStore
    var compact = false
    @State private var actions = ProjectActionsController()
    @AppStorage("workspace.commonApplicationsExpanded") private var commonApplicationsExpanded = true
    @State private var linkDraft: ProjectLink?
    @State private var draftSource = ""
    @State private var showsConfiguration = false

    init(store: WorkspaceStore, compact: Bool = false, configurationExpanded: Bool = false) {
        self.store = store
        self.compact = compact
        _showsConfiguration = State(initialValue: configurationExpanded)
    }

    var body: some View {
        if let project = store.project {
            VStack(alignment: .leading, spacing: 18) {
                quickActions(project)
                feedback
                if compact {
                    let saved = store.preferences(for: project.id).links
                    if !saved.isEmpty {
                        Menu("actions.links") {
                            ForEach(saved) { link in
                                Button(link.name) { actions.open(link.url) }
                            }
                        }
                    }
                } else {
                    Divider()
                    links(project)
                    Divider()
                    ProjectProfileView(store: store)
                    DisclosureGroup(isExpanded: $showsConfiguration) {
                        discovery(project).padding(.top, 12)
                    } label: {
                        HStack {
                            Text("actions.discovered")
                            if store.discovery?.failure != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Spacer()
                            if let result = store.discovery?.value {
                                Text(result.links.count + result.dockerFiles.count + result.packageScripts.count, format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .task(id: project) {
                actions.clearFeedback()
                actions.reloadApplications()
                if !compact && !staticRendering { await store.discoverConfiguration() }
            }
            .sheet(item: $linkDraft) { draft in
                ProjectLinkEditor(link: draft, source: draftSource) { edited in
                    // Capture the project shown when the sheet opens, even if selection later changes.
                    var preferences = store.preferences(for: project.id)
                    preferences.links.removeAll { $0.id == edited.id }
                    preferences.links.append(edited)
                    try store.savePreferences(preferences)
                }
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
            }
        }
    }

    private func quickActions(_ project: ProjectReference) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        let editor = store.preferences(for: project.id).editor
                        Button {
                            Task { await actions.editor(project: project, store: store) }
                        } label: {
                            HStack(spacing: 8) {
                                applicationIcon(
                                    InstalledProjectApplications.icon(for: editor?.applicationURL)
                                        ?? editor.flatMap { InstalledProjectApplications.icon(bundleIdentifier: $0.bundleIdentifier) },
                                    fallback: "chevron.left.forwardslash.chevron.right",
                                    size: 22
                                )
                                Text(editor?.name ?? language.localized("actions.choose-editor"))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        .disabled(actions.isBusy || store.catalogLoadBlocked)
                        .accessibilityIdentifier("menuBar.openEditor")
                        WorkspaceOverflowMenu(title: "actions.more") {
                            Button { Task { await actions.terminal(project.rootDirectory) } } label: {
                                Label("actions.terminal", systemImage: "terminal")
                            }
                            Button { actions.folder(project.rootDirectory) } label: {
                                Label("Finder", systemImage: "folder")
                            }
                            Button("actions.copy-path") { actions.copy(project.rootDirectory.path) }
                            Button("actions.change-editor") { Task { await actions.editor(project: project, store: store, change: true) } }
                                .disabled(store.catalogLoadBlocked)
                        }.disabled(actions.isBusy)
                    }
                    Text("apps.common")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(CommonProjectEditor.allCases) { kind in
                            compactEditorButton(kind, project: project)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        let editor = store.preferences(for: project.id).editor
                        applicationIcon(InstalledProjectApplications.icon(for: editor?.applicationURL) ?? editor.flatMap { InstalledProjectApplications.icon(bundleIdentifier: $0.bundleIdentifier) }, fallback: "chevron.left.forwardslash.chevron.right")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("apps.open-project").font(.caption).foregroundStyle(.secondary)
                            Text(editor?.name ?? language.localized("apps.choose-default")).font(.headline).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(editor == nil ? "apps.choose" : "actions.open") {
                            Task { await actions.editor(project: project, store: store) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(actions.isBusy || store.catalogLoadBlocked)
                        .accessibilityIdentifier("workspace.openEditor")
                        copyAndEditorMenu(project)
                    }
                    DisclosureGroup(isExpanded: $commonApplicationsExpanded) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { applicationTiles(project) }.frame(minWidth: 670)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                applicationTiles(project)
                            }
                        }.padding(.top, 12)
                        HStack {
                            Button("apps.other-editor") { Task { await actions.editor(project: project, store: store, change: true) } }
                                .disabled(actions.isBusy || store.catalogLoadBlocked)
                            Spacer()
                            Button("apps.refresh") { actions.reloadApplications() }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        }.font(.caption).padding(.top, 8)
                    } label: {
                        Text("apps.common").font(.subheadline.weight(.medium))
                    }
                }
            }
        }
    }

    private func compactEditorButton(_ kind: CommonProjectEditor, project: ProjectReference) -> some View {
        let installed = actions.installedEditors[kind]
        let preferred = store.preferences(for: project.id).editor
        let selected = preferred.map { kind.bundleIdentifiers.contains($0.bundleIdentifier) } ?? false
        let title = kind == .intellijIDEA ? "IDEA" : kind.name

        return Button {
            Task { await actions.openCommonEditor(kind, project: project, store: store) }
        } label: {
            HStack(spacing: 6) {
                applicationIcon(InstalledProjectApplications.icon(for: installed?.applicationURL),
                                fallback: kind.symbol, size: 22)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(installed == nil || actions.isBusy || store.catalogLoadBlocked)
        .help(Text(installed == nil ? "apps.not-installed" : selected ? "apps.default" : "apps.use-default"))
        .accessibilityIdentifier("menuBar.commonEditor.\(kind.rawValue)")
    }

    private func copyAndEditorMenu(_ project: ProjectReference) -> some View {
        WorkspaceOverflowMenu(title: "actions.more") {
            Button("actions.change-editor") { Task { await actions.editor(project: project, store: store, change: true) } }
                .disabled(actions.isBusy || store.catalogLoadBlocked)
            Button("actions.copy-path") { actions.copy(project.rootDirectory.path) }
            if let git = store.currentSnapshot?.git {
                Button("actions.copy-branch") { actions.copy(git.branch) }
            }
            ForEach(store.projectProcesses) { process in
                ForEach(process.sockets, id: \.self) { socket in
                    Button("\(socket.transport.rawValue) \(socket.address):\(String(socket.port))") {
                        actions.copy("\(socket.address.contains(":") ? "[\(socket.address)]" : socket.address):\(socket.port)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func applicationTiles(_ project: ProjectReference) -> some View {
        ForEach(CommonProjectEditor.allCases) { kind in
            let installed = actions.installedEditors[kind]
            let preferred = store.preferences(for: project.id).editor
            let selected = preferred.map { kind.bundleIdentifiers.contains($0.bundleIdentifier) } ?? false
            applicationTile(kind == .intellijIDEA ? "IDEA" : kind.name, subtitle: installed == nil ? "apps.not-installed" : selected ? "apps.default" : "apps.use-default",
                            icon: InstalledProjectApplications.icon(for: installed?.applicationURL), symbol: kind.symbol, selected: selected) {
                Task { await actions.openCommonEditor(kind, project: project, store: store) }
            }.disabled(installed == nil || actions.isBusy || store.catalogLoadBlocked)
        }
        applicationTile("Finder", subtitle: "apps.browse-files", icon: InstalledProjectApplications.icon(bundleIdentifier: "com.apple.finder"), symbol: "folder", selected: false) {
            actions.folder(project.rootDirectory)
        }
        applicationTile("Terminal", subtitle: "apps.open-terminal", icon: InstalledProjectApplications.icon(bundleIdentifier: "com.apple.Terminal"), symbol: "terminal", selected: false) {
            Task { await actions.terminal(project.rootDirectory) }
        }.disabled(actions.isBusy)
    }

    private func applicationIcon(_ icon: NSImage?, fallback: String, size: CGFloat = 32) -> some View {
        Group {
            // Some system icons carry HDR data. Keep utility icons at standard range so they
            // don't raise the whole workspace's export range and dim ordinary interface colors.
            if let icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().allowedDynamicRange(.standard) }
            else { Image(systemName: fallback).resizable().scaledToFit().padding(size * 0.1875).foregroundStyle(Color.accentColor) }
        }.frame(width: size, height: size)
    }

    private func applicationTile(_ title: String, subtitle: LocalizedStringKey, icon: NSImage?, symbol: String,
                                 selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                applicationIcon(icon, fallback: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.accentColor) }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07)) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var feedback: some View {
        if let key = actions.feedbackKey { Text(language.localized(key)).font(.caption).foregroundStyle(.secondary) }
        if let failure = actions.failure { Text(failure.localized(in: language)).font(.caption).foregroundStyle(.orange) }
    }

    private func links(_ project: ProjectReference) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("actions.links", systemImage: "link").font(.headline)
                Spacer()
                Button("actions.add-link") {
                    draftSource = ""
                    linkDraft = ProjectLink(name: "", url: URL(string: "http://localhost")!)
                }.disabled(store.catalogLoadBlocked)
            }
            let saved = store.preferences(for: project.id).links
            if saved.isEmpty { Text("actions.no-links").font(.caption).foregroundStyle(.secondary) }
            ForEach(saved) { link in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.name).font(.callout.weight(.medium))
                        Text(link.url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Button("actions.open") { actions.open(link.url) }
                    WorkspaceOverflowMenu(title: "actions.more") {
                        Button("actions.copy-url") { actions.copy(link.url.absoluteString) }
                        Button("actions.edit") { draftSource = ""; linkDraft = link }
                        Button("actions.remove", role: .destructive) {
                            actions.perform {
                                var preferences = store.preferences(for: project.id)
                                preferences.links.removeAll { $0.id == link.id }
                                try store.savePreferences(preferences)
                            }
                        }
                    }.disabled(store.catalogLoadBlocked)
                }
            }
            Text("actions.unverified").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func discovery(_ project: ProjectReference) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("actions.detected-hints").font(.subheadline.weight(.semibold))
                Spacer()
                if store.isDiscovering { ProgressView().controlSize(.small) }
                Button("actions.scan") { Task { await store.discoverConfiguration() } }
                    .disabled(store.isDiscovering)
            }
            Text("actions.scan-scope").font(.caption).foregroundStyle(.secondary)
            if let reading = store.discovery {
                if let failure = reading.failure {
                    Text(failure.localized(in: language)).font(.caption).foregroundStyle(.orange)
                    if reading.value != nil { Text("actions.stale").font(.caption).foregroundStyle(.orange) }
                }
                if let date = reading.checkedAt {
                    HStack(spacing: 5) {
                        Text("actions.last-success")
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                if reading.failure != nil {
                    HStack(spacing: 5) {
                        Text("actions.last-attempt")
                        Text(reading.attemptedAt, format: .dateTime.month().day().hour().minute())
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                if let result = reading.value {
                    if result.links.isEmpty && result.dockerFiles.isEmpty && result.packageScripts.isEmpty && result.issues.isEmpty {
                        Text("actions.no-config").font(.caption).foregroundStyle(.secondary)
                    }
                    if !result.packageScripts.isEmpty {
                        Text(String(format: language.localized("actions.scripts-found"), result.packageScripts.count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(result.links) { link in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                                Text(link.source).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("actions.review") {
                                draftSource = link.source
                                linkDraft = ProjectLink(name: link.name, url: link.url)
                            }.disabled(store.catalogLoadBlocked || reading.failure != nil)
                        }
                    }
                    ForEach(result.issues.indices, id: \.self) { index in
                        Text("\(result.issues[index].source): \(result.issues[index].failure.localized(in: language))")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !result.dockerFiles.isEmpty {
                        Divider()
                        Label("Docker", systemImage: "shippingbox").font(.subheadline.weight(.semibold))
                        ForEach(result.dockerFiles, id: \.self) { name in
                            HStack {
                                Text(name).font(.caption.monospaced())
                                Spacer()
                                Button("actions.reveal") { actions.reveal(name, root: project.rootDirectory) }
                            }
                        }
                        Text("actions.docker-note").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ProjectLinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    let link: ProjectLink
    let source: String
    let save: (ProjectLink) throws -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("actions.review-title").font(.title3.weight(.semibold))
            if !source.isEmpty { Text(source).font(.caption).foregroundStyle(.secondary) }
            TextField("actions.link-name", text: $name)
            TextField("actions.link-url", text: $address)
            Text("actions.link-note").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("projects.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("actions.save") {
                    guard let url = ProjectURLPolicy.validated(address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        error = language.localized("actions.error.invalidURL"); return
                    }
                    do {
                        var edited = link
                        edited.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        edited.url = url
                        try save(edited); dismiss()
                    } catch { self.error = LocalReadFailure.classify(error).localized(in: language) }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { name = link.name; address = link.url.absoluteString }
    }
}
