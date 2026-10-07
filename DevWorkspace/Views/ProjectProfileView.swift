import SwiftUI

struct ProjectProfileView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.workspaceStaticRendering) private var staticRendering
    @Bindable var store: WorkspaceStore
    @State private var candidate: ScriptReview?
    @State private var trustReview: TrustReview?
    @State private var homebrewName = ""
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
                                updateDraft(project) { $0.commands.removeAll { $0.role == role } }
                            }.disabled(store.catalogLoadBlocked)
                        }
                    }
                }
                if availableScripts.isEmpty {
                    Text("profile.no-scripts").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("profile.homebrew").font(.subheadline.weight(.semibold))
                Text("profile.homebrew-note").font(.caption).foregroundStyle(.secondary)
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
                        Spacer()
                        Button("profile.remove", role: .destructive) {
                            updateDraft(project) { $0.homebrewServices.removeAll { $0 == name } }
                        }.disabled(store.catalogLoadBlocked)
                    }
                }
                Text(String(format: language.localized("profile.urls"), store.preferences(for: project.id).links.count))
                    .font(.caption).foregroundStyle(.secondary)
                if !profile.isEmpty {
                    Button("profile.review-trust") {
                        trustReview = TrustReview(projectID: project.id, root: project.rootDirectory,
                            profile: profile, packageDigest: store.discovery?.value?.packageDigest,
                            scripts: availableScripts)
                    }
                    .disabled(store.catalogLoadBlocked || !canReview(profile))
                    .accessibilityIdentifier("workspace.reviewProfileTrust")
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
                                                                 packageDigest: review.packageDigest)
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
        }
    }

    private var availableScripts: [DiscoveredPackageScript] {
        guard store.discovery?.failure == nil else { return [] }
        return store.discovery?.value?.packageScripts ?? []
    }

    private func canReview(_ profile: ProjectProfile) -> Bool {
        profile.commands.isEmpty || (store.discovery?.failure == nil
            && store.discovery?.value?.packageDigest != nil
            && profile.commands.allSatisfy { command in
                availableScripts.contains(where: { $0.name == command.scriptName })
            })
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
    let scripts: [DiscoveredPackageScript]
}
