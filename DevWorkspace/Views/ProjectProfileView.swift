import SwiftUI

struct ProjectProfileView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.workspaceStaticRendering) private var staticRendering
    @Bindable var store: WorkspaceStore
    @State private var candidate: ScriptReview?
    @State private var trustReview: TrustReview?
    @State private var homebrewName = ""
    @State private var javaPath = ""
    @State private var javaExecutable = "/usr/bin/java"
    @State private var javaSpringProfile = ""
    @State private var javaPort = ""
    @State private var confirmsManualProcessResolution = false
    @State private var errorText: String?
    @State private var isTrusting = false

    var body: some View {
        if let project = store.project {
            let profile = store.preferences(for: project.id).profile ?? ProjectProfile()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("profile.title", systemImage: "checklist").font(.headline)
                    Spacer()
                    Text(language.localized(statusKey(store.profileTrustStatus(for: project))))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(store.profileTrustStatus(for: project) == .trusted ? .green : .secondary)
                }
                Text("profile.intro").font(.caption).foregroundStyle(.secondary)
                if let trust = profile.trust {
                    HStack(spacing: 6) {
                        Text("profile.accepted-at")
                        Text(trust.acceptedAt, format: .dateTime.month().day().hour().minute())
                        if let checked = store.discovery?.checkedAt {
                            Text("·")
                            Text("profile.source-checked")
                            Text(checked, format: .dateTime.month().day().hour().minute())
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(ProfileCommandRole.allCases) { role in
                    let command = profile.commands.first { $0.role == role }
                    HStack(spacing: 10) {
                        Text(language.localized("profile.role.\(role.rawValue)"))
                            .frame(width: 60, alignment: .leading)
                        if let command {
                            Text("npm run \(command.scriptName)").font(.caption.monospaced())
                                .textSelection(.enabled)
                        } else {
                            Text("profile.not-set").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("profile.choose-script") {
                            ForEach(availableScripts) { script in
                                Button(script.name) {
                                    candidate = ScriptReview(projectID: project.id, root: project.rootDirectory,
                                                             role: role, script: script,
                                                             scripts: availableScripts)
                                }
                            }
                        }
                        .disabled(availableScripts.isEmpty || store.catalogLoadBlocked)
                        if command != nil {
                            Button("profile.remove", role: .destructive) {
                                updateDraft(project) {
                                    $0.commands.removeAll { $0.role == role }
                                    if role == .start { $0.processReadinessURL = nil }
                                }
                            }.disabled(store.catalogLoadBlocked)
                        }
                    }
                }
                if availableScripts.isEmpty {
                    Text("profile.no-scripts").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("profile.java-title").font(.subheadline.weight(.semibold))
                Text("profile.java-note").font(.caption).foregroundStyle(.secondary)
                TextField("profile.java-path", text: $javaPath).textFieldStyle(.roundedBorder)
                TextField("profile.java-executable", text: $javaExecutable).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("profile.java-spring-profile", text: $javaSpringProfile)
                    TextField("profile.java-port", text: $javaPort)
                }.textFieldStyle(.roundedBorder)
                HStack {
                    Button("profile.java-save") {
                        guard let archive = javaDraft() else { return }
                        updateDraft(project) {
                            $0.javaArchive = archive
                            $0.commands.removeAll { $0.role == .start }
                        }
                    }.disabled(javaDraft() == nil || store.catalogLoadBlocked)
                    if profile.javaArchive != nil {
                        Button("profile.remove", role: .destructive) {
                            updateDraft(project) { $0.javaArchive = nil; $0.processReadinessURL = nil }
                        }.disabled(store.catalogLoadBlocked)
                    }
                }
                if let source = store.javaArchiveSource {
                    if let value = source.value {
                        Text("SHA-256: \(value.digest) · \(value.byteCount) bytes")
                            .font(.caption2.monospaced()).textSelection(.enabled)
                    }
                    if let failure = source.failure {
                        Label(failure.localized(in: language), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Divider()
                Text("profile.homebrew").font(.subheadline.weight(.semibold))
                Text("profile.homebrew-note").font(.caption).foregroundStyle(.secondary)
                if let reading = store.homebrewServices {
                    if let failure = reading.failure {
                        Label(failure.localized(in: language), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Text("profile.homebrew-last-trusted")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(reading.attemptedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let checkedAt = reading.checkedAt {
                        HStack(spacing: 4) {
                            Text(LocalizedStringKey(reading.failure == nil
                                ? "workspace.snapshot.updated-at" : "workspace.snapshot.last-trusted-at"))
                            Text(checkedAt, format: .dateTime.month().day().hour().minute().second())
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if staticRendering {
                        Text("profile.homebrew-placeholder").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        TextField("profile.homebrew-placeholder", text: $homebrewName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addHomebrew(project) }
                    }
                    Button("profile.add") { addHomebrew(project) }
                        .disabled(!ProjectProfile.validHomebrewName(homebrewName) || store.catalogLoadBlocked)
                }
                ForEach(profile.homebrewServices, id: \.self) { name in
                    HStack {
                        Text(name).font(.caption.monospaced())
                        if let status = store.homebrewServices?.value?.first(where: { $0.name == name }) {
                            Text(LocalizedStringKey("profile.homebrew-state.\(status.state.rawValue)"))
                                .font(.caption).foregroundStyle(status.state == .running ? .green : .secondary)
                            if let pid = status.pid { Text("PID \(pid)").font(.caption2).foregroundStyle(.secondary) }
                        } else {
                            Text("profile.homebrew-state.unread").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("profile.remove", role: .destructive) {
                            updateDraft(project) { $0.homebrewServices.removeAll { $0 == name } }
                        }.disabled(store.catalogLoadBlocked)
                    }
                }
                if !profile.homebrewServices.isEmpty {
                    Button("profile.homebrew-refresh") {
                        Task { await store.refreshHomebrewServices() }
                    }.disabled(store.isRefreshingHomebrewServices)
                }
                Divider()
                HStack {
                    Text("profile.compose-title").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let name = profile.composeConfigurationName {
                        Text(name).font(.caption.monospaced())
                        Button("profile.remove", role: .destructive) {
                            updateDraft(project) {
                                $0.composeConfigurationName = nil
                                $0.composeReadinessURL = nil
                            }
                        }
                    } else if let name = store.discovery?.value?.composeConfigurationName {
                        Button("profile.compose-add") {
                            updateDraft(project) { $0.composeConfigurationName = name }
                        }.disabled(store.discovery?.failure != nil)
                    } else {
                        Text("profile.compose-unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("profile.compose-note").font(.caption).foregroundStyle(.secondary)
                Text(String(format: language.localized("profile.urls"), store.preferences(for: project.id).links.count))
                    .font(.caption).foregroundStyle(.secondary)
                if !profile.isEmpty {
                    Button("profile.review-trust") {
                        trustReview = TrustReview(projectID: project.id, root: project.rootDirectory,
                            profile: profile, packageDigest: store.discovery?.value?.packageDigest,
                            composeDigest: store.discovery?.value?.composeDigest,
                            javaDigest: store.javaArchiveSource?.value?.digest,
                            javaByteCount: store.javaArchiveSource?.value?.byteCount,
                            composeContents: store.discovery?.value?.composeContents,
                            scripts: availableScripts)
                    }
                    .disabled(store.catalogLoadBlocked || !canReview(profile))
                    .accessibilityIdentifier("workspace.reviewProfileTrust")
                }
                if profile.commands.contains(where: { $0.role == .start }) || profile.javaArchive != nil
                    || store.managedProcess != nil || store.managedComposeRun != nil {
                    Divider()
                    Text("profile.workspace-title").font(.subheadline.weight(.semibold))
                    Text("profile.workspace-note").font(.caption).foregroundStyle(.secondary)
                    Text(LocalizedStringKey(workspacePhaseKey(store.workspacePhase)))
                        .font(.caption).foregroundStyle(.secondary)
                    if case let .failed(failure) = store.workspacePhase {
                        Label(LocalizedStringKey("profile.workspace-error.\(failure.rawValue)"),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("profile.workspace-start") { store.startSelectedWorkspace() }
                            .disabled(profile.trust == nil || store.isWorkspaceBusy || executionIsBusy
                                || composeIsBusy || store.pendingProjectLaunch != nil
                                || store.pendingComposeStart != nil || store.catalogLoadBlocked)
                            .accessibilityIdentifier("workspace.startWorkspace")
                        Button("profile.workspace-stop") { store.stopSelectedWorkspace() }
                            .disabled(store.isWorkspaceBusy || executionIsBusy || composeIsBusy
                                || (store.managedProcess == nil && store.managedComposeRun == nil))
                            .accessibilityIdentifier("workspace.stopWorkspace")
                        if store.isWorkspaceBusy {
                            Button("projects.cancel") { store.cancelSelectedWorkspaceStart() }
                        }
                    }
                }
                if profile.commands.contains(where: { $0.role == .start }) || profile.javaArchive != nil
                    || store.managedProcess != nil || store.pendingProjectLaunch != nil {
                    Divider()
                    Text("profile.execution-title").font(.subheadline.weight(.semibold))
                    Text("profile.execution-note").font(.caption).foregroundStyle(.secondary)
                    readinessSelection(project: project, compose: false, selected: profile.processReadinessURL)
                    if let record = store.managedProcess {
                        let commandLabel = record.javaArchiveRelativePath.map { "java -jar \($0)" }
                            ?? "npm run \(record.scriptName)"
                        Text("\(commandLabel) · PID \(record.identity.pid)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text(record.identity.executablePath).font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let archive = profile.javaArchive {
                        Text("java -jar \(archive.relativePath)").font(.caption.monospaced())
                    } else if let command = profile.commands.first(where: { $0.role == .start }) {
                        Text("npm run \(command.scriptName)").font(.caption.monospaced())
                    }
                    if let pending = store.pendingProjectLaunch {
                        Label("\(pending.commandLabel) · \(pending.pid.map(String.init) ?? "PID 未记录")",
                              systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.orange)
                        Text("profile.pending-process-note").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(LocalizedStringKey(phaseKey(store.executionPhase)))
                        .font(.caption).foregroundStyle(.secondary)
                    if case let .failed(failure) = store.executionPhase {
                        Label(LocalizedStringKey("profile.execution-error.\(failure.rawValue)"),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        if store.managedProcess == nil {
                            Button("profile.execution-start") { store.startSelectedProject() }
                                .disabled(store.profileTrustStatus(for: project) != .trusted
                                    || executionIsBusy || composeIsBusy || store.catalogLoadBlocked
                                    || store.pendingProjectLaunch != nil)
                        } else {
                            Button("profile.execution-stop") { store.stopSelectedProject() }
                                .disabled(executionIsBusy || composeIsBusy)
                            if case .failed(.readinessTimedOut) = store.executionPhase {
                                Button("profile.execution-retry") { store.retryReadiness() }
                                    .disabled(executionIsBusy || composeIsBusy)
                            }
                        }
                        if executionIsBusy && store.executionPhase != .stopping {
                            Button("projects.cancel") { store.cancelSelectedProjectStart() }
                        }
                        if store.pendingProjectLaunch != nil {
                            Button("profile.pending-retry") { store.retryPendingProjectCleanup() }
                                .disabled(executionIsBusy || composeIsBusy)
                            Button("profile.pending-acknowledge") { confirmsManualProcessResolution = true }
                                .disabled(executionIsBusy || composeIsBusy)
                        }
                    }
                }
                if profile.composeConfigurationName != nil || store.managedComposeRun != nil
                    || store.pendingComposeStart != nil {
                    Divider()
                    Text("profile.compose-control-title").font(.subheadline.weight(.semibold))
                    Text("profile.compose-control-note").font(.caption).foregroundStyle(.secondary)
                    if profile.composeConfigurationName != nil {
                        readinessSelection(project: project, compose: true, selected: profile.composeReadinessURL)
                    }
                    if let run = store.managedComposeRun {
                        Text(String(format: language.localized("profile.compose-managed-count"), run.containerIDs.count))
                            .font(.caption)
                    }
                    Text(LocalizedStringKey(composePhaseKey(store.composePhase)))
                        .font(.caption).foregroundStyle(.secondary)
                    if case let .failed(failure) = store.composePhase {
                        Label(LocalizedStringKey("profile.compose-error.\(failure.rawValue)"),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        if store.managedComposeRun == nil {
                            Button("profile.compose-start") { store.startSelectedCompose() }
                                .disabled(store.profileTrustStatus(for: project) != .trusted
                                    || composeIsBusy || executionIsBusy || store.catalogLoadBlocked
                                    || store.pendingComposeStart != nil)
                        } else {
                            Button("profile.compose-stop") { store.stopSelectedCompose() }
                                .disabled(composeIsBusy || executionIsBusy)
                            if case .failed(.readinessTimedOut) = store.composePhase {
                                Button("profile.execution-retry") { store.retryComposeReadiness() }
                                    .disabled(composeIsBusy || executionIsBusy)
                            }
                        }
                        if composeIsBusy && store.composePhase != .stopping {
                            Button("projects.cancel") { store.cancelSelectedComposeStart() }
                        }
                        if store.pendingComposeStart != nil {
                            Button("profile.pending-compose-recover") { store.recoverPendingComposeStart() }
                                .disabled(composeIsBusy || executionIsBusy)
                        }
                    }
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
            }
            .sheet(item: $candidate) { review in
                VStack(alignment: .leading, spacing: 16) {
                    Text("profile.preview-title").font(.title3.weight(.semibold))
                    commandPreview(name: review.script.name, root: review.root, scripts: review.scripts)
                    Text("profile.preview-warning").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("projects.cancel") { candidate = nil }.keyboardShortcut(.cancelAction)
                        Button("profile.save-draft") {
                            guard store.project?.id == review.projectID else {
                                errorText = language.localized("profile.error.project-changed"); candidate = nil; return
                            }
                            updateDraft(project) { draft in
                                draft.commands.removeAll { $0.role == review.role }
                                draft.commands.append(ProfileScriptCommand(role: review.role, scriptName: review.script.name))
                                if review.role == .start { draft.javaArchive = nil }
                            }
                            candidate = nil
                        }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24).frame(width: 600)
            }
            .sheet(item: $trustReview) { review in
                VStack(alignment: .leading, spacing: 16) {
                    Text("profile.trust-title").font(.title3.weight(.semibold))
                    Text("profile.trust-note").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(review.profile.commands) { command in
                                Text(language.localized("profile.role.\(command.role.rawValue)"))
                                    .font(.subheadline.weight(.semibold))
                                commandPreview(name: command.scriptName, root: review.root, scripts: review.scripts)
                            }
                            if !review.profile.homebrewServices.isEmpty {
                                Text("profile.homebrew").font(.subheadline.weight(.semibold))
                                Text(review.profile.homebrewServices.joined(separator: ", "))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let name = review.profile.composeConfigurationName {
                                Text("profile.compose-title").font(.subheadline.weight(.semibold))
                                Text(name).font(.caption.monospaced())
                                Text(review.composeContents ?? "").font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            if let archive = review.profile.javaArchive {
                                Text("profile.java-title").font(.subheadline.weight(.semibold))
                                Text("\(archive.executablePath) -jar \(archive.relativePath)")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                if let spring = archive.springProfile {
                                    Text("--spring.profiles.active=\(spring)").font(.caption.monospaced())
                                }
                                if let port = archive.serverPort {
                                    Text("--server.port=\(port)").font(.caption.monospaced())
                                }
                                Text("SHA-256: \(review.javaDigest ?? "—") · \(review.javaByteCount ?? 0) bytes")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let url = review.profile.processReadinessURL {
                                Text("profile.execution-title").font(.subheadline.weight(.semibold))
                                Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if let url = review.profile.composeReadinessURL {
                                Text("profile.compose-control-title").font(.subheadline.weight(.semibold))
                                Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 380)
                    Text("profile.preview-warning").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("projects.cancel") { trustReview = nil }.keyboardShortcut(.cancelAction)
                        Button("profile.confirm-trust") {
                            isTrusting = true
                            Task {
                                defer { isTrusting = false }
                                do {
                                    try await store.trustProfile(for: review.projectID, reviewed: review.profile,
                                                                 packageDigest: review.packageDigest,
                                                                 composeDigest: review.composeDigest,
                                                                 javaDigest: review.javaDigest)
                                    errorText = nil
                                    trustReview = nil
                                } catch { errorText = message(for: error); trustReview = nil }
                            }
                        }
                        .disabled(isTrusting)
                        .keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 600)
            }
            .task(id: profile.homebrewServices) {
                if !staticRendering { await store.refreshHomebrewServices() }
            }
            .task(id: profile.javaArchive) {
                if !staticRendering { await store.refreshJavaArchiveSource() }
            }
            .task(id: project.id) {
                let archive = profile.javaArchive
                javaPath = archive?.relativePath ?? ""
                javaExecutable = archive?.executablePath ?? "/usr/bin/java"
                javaSpringProfile = archive?.springProfile ?? ""
                javaPort = archive?.serverPort.map(String.init) ?? ""
            }
            .confirmationDialog("profile.pending-confirm-title", isPresented: $confirmsManualProcessResolution) {
                Button("profile.pending-confirm", role: .destructive) {
                    store.acknowledgePendingProjectLaunch()
                }
            } message: { Text("profile.pending-confirm-message") }
        }
    }

    private var availableScripts: [DiscoveredPackageScript] {
        guard store.discovery?.failure == nil else { return [] }
        return store.discovery?.value?.packageScripts ?? []
    }

    private func javaDraft() -> ProfileJavaArchive? {
        let path = javaPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = javaExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
        let spring = javaSpringProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = javaPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard portText.isEmpty || UInt16(portText) != nil else { return nil }
        let archive = ProfileJavaArchive(relativePath: path, executablePath: executable,
            springProfile: spring.isEmpty ? nil : spring, serverPort: UInt16(portText))
        return archive.isValid ? archive : nil
    }

    private var localReadinessLinks: [ProjectLink] {
        guard let project = store.project else { return [] }
        return store.preferences(for: project.id).links.filter {
            ProjectProfile.validReadinessURL($0.url)
        }
    }

    private func readinessSelection(project: ProjectReference, compose: Bool, selected: URL?) -> some View {
        HStack(spacing: 8) {
            Text("profile.readiness-url").font(.caption)
            if let url = selected ?? localReadinessLinks.first?.url {
                Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("profile.readiness-none").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("profile.choose-readiness") {
                Button("profile.readiness-auto") {
                    updateDraft(project) {
                        if compose { $0.composeReadinessURL = nil }
                        else { $0.processReadinessURL = nil }
                    }
                }
                ForEach(localReadinessLinks) { link in
                    Button("\(link.name) · \(link.url.absoluteString)") {
                        updateDraft(project) {
                            if compose { $0.composeReadinessURL = link.url }
                            else { $0.processReadinessURL = link.url }
                        }
                    }
                }
            }.disabled(store.catalogLoadBlocked)
        }
    }

    private var executionIsBusy: Bool {
        switch store.executionPhase {
        case .validating, .launching, .checkingReadiness, .stopping: true
        default: false
        }
    }

    private func phaseKey(_ phase: ProjectExecutionPhase) -> String {
        switch phase {
        case .idle: "profile.execution.idle"
        case .validating: "profile.execution.validating"
        case .launching: "profile.execution.launching"
        case .checkingReadiness: "profile.execution.checking"
        case .ready: "profile.execution.ready"
        case .stopping: "profile.execution.stopping"
        case .stopped: "profile.execution.stopped"
        case .cancelled: "profile.execution.cancelled"
        case .recoveryRequired: "profile.execution.recovery"
        case .failed: "profile.execution.failed"
        }
    }

    private func workspacePhaseKey(_ phase: WorkspaceControlPhase) -> String {
        switch phase {
        case .idle: "profile.workspace.idle"
        case .validating: "profile.workspace.validating"
        case .startingDependencies: "profile.workspace.dependencies"
        case .startingApplication: "profile.workspace.application"
        case .ready: "profile.workspace.ready"
        case .stoppingApplication: "profile.workspace.stopping-application"
        case .stoppingDependencies: "profile.workspace.stopping-dependencies"
        case .stopped: "profile.workspace.stopped"
        case .cancelled: "profile.workspace.cancelled"
        case .recoveryRequired: "profile.workspace.recovery"
        case .failed: "profile.workspace.failed"
        }
    }

    private var composeIsBusy: Bool {
        switch store.composePhase {
        case .validating, .starting, .checkingReadiness, .stopping: true
        default: false
        }
    }

    private func composePhaseKey(_ phase: ComposeExecutionPhase) -> String {
        switch phase {
        case .idle: "profile.compose.idle"
        case .validating: "profile.compose.validating"
        case .starting: "profile.compose.starting"
        case .checkingReadiness: "profile.compose.checking"
        case .ready: "profile.compose.ready"
        case .stopping: "profile.compose.stopping"
        case .stopped: "profile.compose.stopped"
        case .cancelled: "profile.compose.cancelled"
        case .recoveryRequired: "profile.compose.recovery"
        case .failed: "profile.compose.failed"
        }
    }

    private func canReview(_ profile: ProjectProfile) -> Bool {
        let commandsReady = profile.commands.isEmpty || (store.discovery?.failure == nil
            && store.discovery?.value?.packageDigest != nil
            && profile.commands.allSatisfy { command in
                availableScripts.contains(where: { $0.name == command.scriptName })
            })
        let composeReady = profile.composeConfigurationName == nil
            || (store.discovery?.failure == nil
                && store.discovery?.value?.composeConfigurationName == profile.composeConfigurationName
                && store.discovery?.value?.composeDigest != nil)
        let javaReady = profile.javaArchive == nil || (store.javaArchiveSource?.failure == nil
            && store.javaArchiveSource?.value != nil)
        return commandsReady && composeReady && javaReady
    }

    private func updateDraft(_ project: ProjectReference, change: (inout ProjectProfile) -> Void) {
        guard store.project?.id == project.id else { return }
        var draft = store.preferences(for: project.id).profile ?? ProjectProfile()
        change(&draft)
        do { try store.saveProfileDraft(draft, for: project.id); errorText = nil }
        catch { errorText = message(for: error) }
    }

    private func addHomebrew(_ project: ProjectReference) {
        let name = homebrewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectProfile.validHomebrewName(name) else {
            errorText = language.localized("profile.error.invalid-name"); return
        }
        if store.preferences(for: project.id).profile?.homebrewServices.contains(name) == true {
            homebrewName = ""; return
        }
        updateDraft(project) { draft in
            draft.homebrewServices.append(name)
        }
        if errorText == nil { homebrewName = "" }
    }

    private func commandPreview(name: String, root: URL, scripts: [DiscoveredPackageScript]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("npm run \(name)").font(.callout.monospaced().weight(.medium)).textSelection(.enabled)
            Text(root.path).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(["pre\(name)", name, "post\(name)"], id: \.self) { key in
                if let script = scripts.first(where: { $0.name == key }) {
                    Text("\(key): \(script.body)").font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statusKey(_ status: ProfileTrustStatus) -> String {
        switch status {
        case .absent: "profile.status.absent"
        case .draft: "profile.status.draft"
        case .needsScan: "profile.status.needs-scan"
        case .sourceChanged: "profile.status.changed"
        case .trusted: "profile.status.trusted"
        }
    }

    private func message(for error: any Error) -> String {
        if let failure = error as? ProfileFailure {
            switch failure {
            case .invalidProfile: return language.localized("profile.error.invalid-profile")
            case .reviewChanged: return language.localized("profile.error.review-changed")
            case .missingScript: return language.localized("profile.error.missing-script")
            case .projectChanged: return language.localized("profile.error.project-changed")
            }
        }
        return LocalReadFailure.classify(error).localized(in: language)
    }
}

private struct ScriptReview: Identifiable {
    let id = UUID()
    let projectID: ProjectIdentifier
    let root: URL
    let role: ProfileCommandRole
    let script: DiscoveredPackageScript
    let scripts: [DiscoveredPackageScript]
}

private struct TrustReview: Identifiable {
    let id = UUID()
    let projectID: ProjectIdentifier
    let root: URL
    let profile: ProjectProfile
    let packageDigest: String?
    let composeDigest: String?
    let javaDigest: String?
    let javaByteCount: Int64?
    let composeContents: String?
    let scripts: [DiscoveredPackageScript]
}
