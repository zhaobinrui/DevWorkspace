import Foundation
import XCTest
@testable import DevWorkspace

@MainActor
final class CommonCapabilityTests: XCTestCase {
    func test_notificationSettings_whenAuthorizationIsGranted_shouldPersistPreferences()
        async
    {
        let suiteName = "DevWorkspaceTests.Notifications.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = TestNotificationManager(authorizationState: .authorized)
        let settings = NotificationSettings(userDefaults: userDefaults)

        await settings.setEnabled(true, using: manager)
        settings.notifyOnNeedsAttention = false

        let restored = NotificationSettings(userDefaults: userDefaults)
        await restored.refreshAuthorization(using: manager)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertTrue(restored.notifyOnFailure)
        XCTAssertFalse(restored.notifyOnNeedsAttention)
        XCTAssertEqual(restored.authorizationState, .authorized)
    }

    func test_notificationSettings_whenAuthorizationIsDenied_shouldRemainDisabled()
        async
    {
        let suiteName = "DevWorkspaceTests.Notifications.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = TestNotificationManager(authorizationState: .denied)
        let settings = NotificationSettings(userDefaults: userDefaults)

        await settings.setEnabled(true, using: manager)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.authorizationState, .denied)
        XCTAssertFalse(userDefaults.bool(forKey: NotificationSettings.enabledKey))
    }

    func test_notificationIncidentTracker_whenFailureRepeats_shouldDeliverOnceUntilRecovery() {
        var tracker = WorkspaceNotificationIncidentTracker()

        XCTAssertEqual(
            tracker.notificationToDeliver(
                for: .actionable(.failure),
                isAllowed: { _ in true }
            ),
            .failure
        )
        XCTAssertNil(
            tracker.notificationToDeliver(
                for: .unchanged,
                isAllowed: { _ in true }
            )
        )
        XCTAssertNil(
            tracker.notificationToDeliver(
                for: .actionable(.failure),
                isAllowed: { _ in true }
            )
        )
        XCTAssertNil(
            tracker.notificationToDeliver(
                for: .recovered,
                isAllowed: { _ in true }
            )
        )
        XCTAssertEqual(
            tracker.notificationToDeliver(
                for: .actionable(.failure),
                isAllowed: { _ in true }
            ),
            .failure
        )
    }

    func test_notificationCoordinator_whenFailureRepeats_shouldDeliverGenericMessageOnce()
        async throws
    {
        let suiteName = "DevWorkspaceTests.Notifications.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = TestNotificationManager(authorizationState: .authorized)
        let settings = NotificationSettings(userDefaults: userDefaults)
        await settings.setEnabled(true, using: manager)
        let languageSettings = AppLanguageSettings(
            userDefaults: userDefaults,
            defaultLanguage: .english
        )
        let store = WorkspaceStore(
            project: try makeProject(name: "Secret Project"),
            provider: CommonScriptedSnapshotProvider([
                .failure("token=secret; /private/project/path"),
                .failure("token=secret; /private/project/path"),
            ])
        )
        let coordinator = WorkspaceNotificationCoordinator(
            store: store,
            settings: settings,
            languageSettings: languageSettings,
            manager: manager
        )
        coordinator.start()
        defer { coordinator.stop() }

        await store.refresh()
        try await waitUntil { manager.deliveredNotifications.count == 1 }
        await store.refresh()
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(manager.deliveredNotifications.count, 1)
        let notification = try XCTUnwrap(manager.deliveredNotifications.first)
        XCTAssertFalse(notification.title.contains("Secret Project"))
        XCTAssertFalse(notification.body.contains("secret"))
        XCTAssertFalse(notification.body.contains("/private"))
    }

    func test_refreshPolicy_whenVisibilityAndConditionChange_shouldUseAdaptiveIntervals()
        throws
    {
        let policy = WorkspaceRefreshPolicy()
        let project = try makeProject()
        let stable = WorkspaceStore.State.ready(
            makeSnapshot(project: project, lifecycle: .ready)
        )
        let transient = WorkspaceStore.State.ready(
            makeSnapshot(project: project, lifecycle: .starting)
        )
        let problem = WorkspaceStore.State.failed(
            message: .provider("offline")
        )

        XCTAssertEqual(
            policy.interval(for: stable, visibility: .visible),
            60
        )
        XCTAssertEqual(
            policy.interval(for: stable, visibility: .background),
            300
        )
        XCTAssertEqual(
            policy.interval(for: transient, visibility: .visible),
            5
        )
        XCTAssertEqual(
            policy.interval(for: transient, visibility: .background),
            30
        )
        XCTAssertEqual(
            policy.interval(for: problem, visibility: .visible),
            30
        )
        XCTAssertEqual(
            policy.interval(for: problem, visibility: .background),
            120
        )
    }

    func test_refreshController_whenStopped_shouldCancelFutureScheduledRefreshes()
        async throws
    {
        let project = try makeProject()
        let provider = CountingSnapshotProvider()
        let store = WorkspaceStore(project: project, provider: provider)
        let fastPolicy = WorkspaceRefreshPolicy(
            visibleStableInterval: 0.01,
            visibleTransientInterval: 0.01,
            visibleProblemInterval: 0.01,
            backgroundStableInterval: 0.01,
            backgroundTransientInterval: 0.01,
            backgroundProblemInterval: 0.01
        )
        let controller = WorkspaceRefreshController(
            store: store,
            policy: fastPolicy
        )

        controller.start()
        try await waitUntil {
            controller.metrics.completedRefreshCount >= 2
        }
        controller.stop()
        let countAfterStop = await provider.snapshotCount
        try await Task.sleep(for: .milliseconds(50))
        let finalCount = await provider.snapshotCount

        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.metrics.nextRefreshAt)
        XCTAssertNil(controller.metrics.scheduledInterval)
        XCTAssertGreaterThanOrEqual(controller.metrics.scheduledWakeCount, 1)
        XCTAssertEqual(finalCount, countAfterStop)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Condition was not met before timeout")
    }

    private func makeProject(name: String = "Example") throws -> ProjectReference {
        let identity = try LocalProjectIdentityResolver().resolve(
            rootDirectory: URL(
                fileURLWithPath: "/private/tmp/common-capability-tests",
                isDirectory: true
            ),
            declaredMetadataID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000087"
            )
        )
        return ProjectReference(identity: identity, name: name)
    }

    private func makeSnapshot(
        project: ProjectReference,
        lifecycle: WorkspaceLifecycle
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            project: project,
            lifecycle: lifecycle,
            git: nil,
            services: [],
            observedAt: .now,
            freshness: .current,
            origin: .local
        )
    }
}

@MainActor
private final class TestNotificationManager: UserNotificationManaging {
    private(set) var state: NotificationAuthorizationState
    private(set) var deliveredNotifications: [WorkspaceLocalNotification] = []

    init(authorizationState: NotificationAuthorizationState) {
        state = authorizationState
    }

    func authorizationState() async -> NotificationAuthorizationState {
        state
    }

    func requestAuthorization() async -> NotificationAuthorizationState {
        state
    }

    func deliver(_ notification: WorkspaceLocalNotification) async throws {
        deliveredNotifications.append(notification)
    }
}

private actor CommonScriptedSnapshotProvider: WorkspaceSnapshotProviding {
    enum Outcome: Sendable {
        case snapshot(WorkspaceSnapshot)
        case failure(String)
    }

    private var outcomes: [Outcome]

    init(_ outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        guard !outcomes.isEmpty else {
            throw CommonTestProviderError(message: "No scripted outcome")
        }

        return switch outcomes.removeFirst() {
        case let .snapshot(snapshot):
            snapshot
        case let .failure(message):
            throw CommonTestProviderError(message: message)
        }
    }
}

private actor CountingSnapshotProvider: WorkspaceSnapshotProviding {
    private(set) var snapshotCount = 0

    func snapshot(for project: ProjectReference) async throws -> WorkspaceSnapshot {
        snapshotCount += 1
        return WorkspaceSnapshot(
            project: project,
            lifecycle: .ready,
            git: nil,
            services: [],
            observedAt: .now,
            freshness: .current,
            origin: .local
        )
    }
}

private struct CommonTestProviderError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
