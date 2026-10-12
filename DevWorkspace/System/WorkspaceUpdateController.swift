import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class WorkspaceUpdateController {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    let isConfigured: Bool

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticObservation: NSKeyValueObservation?

    init(configuration: UpdateConfiguration? = UpdateConfiguration(bundle: .main)) {
        isConfigured = configuration != nil
    }

    func start() {
        guard isConfigured, controller == nil else { return }

        // Sparkle reads the validated feed and public key from Info.plist. A preview build
        // without either value never creates an updater or makes an update-network request.
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller = updaterController
        checkObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = enabled
            }
        }
        automaticObservation = updaterController.updater.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = enabled
            }
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        // Sparkle owns this preference and its scheduling; never mirror it in app defaults.
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
