import Foundation
import Observation
import UserNotifications

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct WorkspaceLocalNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}

@MainActor
protocol UserNotificationManaging: AnyObject {
    func authorizationState() async -> NotificationAuthorizationState
    func requestAuthorization() async -> NotificationAuthorizationState
    func deliver(_ notification: WorkspaceLocalNotification) async throws
}

@MainActor
final class SystemUserNotificationManager: UserNotificationManaging {
    private let notificationCenter: UNUserNotificationCenter

    init(notificationCenter: UNUserNotificationCenter = .current()) {
        self.notificationCenter = notificationCenter
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await notificationCenter.notificationSettings()
        return Self.authorizationState(for: settings.authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorizationState {
        do {
            _ = try await notificationCenter.requestAuthorization(
                options: [.alert]
            )
        } catch {
            return .denied
        }

        return await authorizationState()
    }

    func deliver(_ notification: WorkspaceLocalNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body

        // 使用稳定标识替换同类待送达提醒，同时刻意不加入项目名、路径或错误原文，
        // 避免本地通知在锁屏或共享屏幕上泄露开发上下文。
        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        try await notificationCenter.add(request)
    }

    private static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized, .provisional, .ephemeral:
            .authorized
        @unknown default:
            .denied
        }
    }
}

@MainActor
@Observable
final class NotificationSettings {
    static let enabledKey = "notifications.enabled"
    static let failureKey = "notifications.failure"
    static let needsAttentionKey = "notifications.needs-attention"

    private(set) var isEnabled: Bool
    var notifyOnFailure: Bool {
        didSet {
            persist(
                notifyOnFailure,
                key: Self.failureKey,
                oldValue: oldValue
            )
        }
    }
    var notifyOnNeedsAttention: Bool {
        didSet {
            persist(
                notifyOnNeedsAttention,
                key: Self.needsAttentionKey,
                oldValue: oldValue
            )
        }
    }
    private(set) var authorizationState: NotificationAuthorizationState
    private(set) var isRequestingAuthorization = false

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.bool(forKey: Self.enabledKey)
        notifyOnFailure = userDefaults.object(forKey: Self.failureKey) as? Bool
            ?? true
        notifyOnNeedsAttention = userDefaults.object(
            forKey: Self.needsAttentionKey
        ) as? Bool ?? true
        authorizationState = .notDetermined
    }

    func refreshAuthorization(
        using manager: any UserNotificationManaging
    ) async {
        authorizationState = await manager.authorizationState()
        if authorizationState != .authorized, isEnabled {
            setEnabledWithoutAuthorization(false)
        }
    }

    func setEnabled(
        _ requestedValue: Bool,
        using manager: any UserNotificationManaging
    ) async {
        guard requestedValue else {
            setEnabledWithoutAuthorization(false)
            return
        }

        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }

        let currentState = await manager.authorizationState()
        authorizationState = currentState == .notDetermined
            ? await manager.requestAuthorization()
            : currentState
        setEnabledWithoutAuthorization(
            authorizationState == .authorized
        )
    }

    func allows(_ kind: WorkspaceNotificationKind) -> Bool {
        guard isEnabled, authorizationState == .authorized else {
            return false
        }

        return switch kind {
        case .failure:
            notifyOnFailure
        case .needsAttention:
            notifyOnNeedsAttention
        }
    }

    private func setEnabledWithoutAuthorization(_ enabled: Bool) {
        guard isEnabled != enabled else {
            return
        }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledKey)
    }

    private func persist(_ value: Bool, key: String, oldValue: Bool) {
        guard value != oldValue else {
            return
        }
        userDefaults.set(value, forKey: key)
    }
}

enum WorkspaceNotificationKind: String, Equatable, Sendable {
    case failure
    case needsAttention

    func notification(in language: AppLanguage) -> WorkspaceLocalNotification {
        let keyPrefix = switch self {
        case .failure:
            "notification.workspace.failure"
        case .needsAttention:
            "notification.workspace.needs-attention"
        }

        return WorkspaceLocalNotification(
            identifier: "devworkspace.workspace.\(rawValue)",
            title: language.localized("\(keyPrefix).title"),
            body: language.localized("\(keyPrefix).body")
        )
    }
}

enum WorkspaceNotificationSignal: Equatable, Sendable {
    case unchanged
    case recovered
    case actionable(WorkspaceNotificationKind)
}

enum WorkspaceNotificationPolicy {
    static func signal(
        for state: WorkspaceStore.State
    ) -> WorkspaceNotificationSignal {
        switch state {
        case .idle, .refreshing:
            .unchanged
        case .failed:
            .actionable(.failure)
        case .degraded:
            .actionable(.needsAttention)
        case let .ready(snapshot):
            switch snapshot.lifecycle {
            case .stopped, .ready:
                .recovered
            case .starting:
                .unchanged
            case .degraded:
                .actionable(.needsAttention)
            case .failed:
                .actionable(.failure)
            }
        }
    }
}

struct WorkspaceNotificationIncidentTracker: Sendable {
    private var deliveredKind: WorkspaceNotificationKind?

    mutating func notificationToDeliver(
        for signal: WorkspaceNotificationSignal,
        isAllowed: (WorkspaceNotificationKind) -> Bool
    ) -> WorkspaceNotificationKind? {
        switch signal {
        case .unchanged:
            return nil
        case .recovered:
            deliveredKind = nil
            return nil
        case let .actionable(kind):
            guard kind != deliveredKind, isAllowed(kind) else {
                return nil
            }

            // 先锁定事件再异步投递，避免状态观察在系统 API 返回前重复排队同一提醒。
            deliveredKind = kind
            return kind
        }
    }
}

@MainActor
final class WorkspaceNotificationCoordinator {
    private let store: WorkspaceStore
    private let settings: NotificationSettings
    private let languageSettings: AppLanguageSettings
    private let manager: any UserNotificationManaging

    private var incidentTracker = WorkspaceNotificationIncidentTracker()
    private var isRunning = false
    private var deliveryTask: Task<Void, Never>?

    init(
        store: WorkspaceStore,
        settings: NotificationSettings,
        languageSettings: AppLanguageSettings,
        manager: any UserNotificationManaging
    ) {
        self.store = store
        self.settings = settings
        self.languageSettings = languageSettings
        self.manager = manager
    }

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        observeState()
        evaluateState()
    }

    func stop() {
        isRunning = false
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    private func observeState() {
        guard isRunning else {
            return
        }

        // Observation 的回调只覆盖下一次变化；每次回调后重新注册，才能同时跟踪
        // 工作区状态、通知偏好和语言，又不引入固定频率的额外轮询。
        withObservationTracking {
            _ = store.state
            _ = settings.isEnabled
            _ = settings.notifyOnFailure
            _ = settings.notifyOnNeedsAttention
            _ = settings.authorizationState
            _ = languageSettings.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else {
                    return
                }
                self.observeState()
                self.evaluateState()
            }
        }
    }

    private func evaluateState() {
        let signal = WorkspaceNotificationPolicy.signal(for: store.state)
        guard let kind = incidentTracker.notificationToDeliver(
            for: signal,
            isAllowed: { settings.allows($0) }
        ) else {
            return
        }

        let notification = kind.notification(in: languageSettings.language)
        deliveryTask?.cancel()
        deliveryTask = Task { [manager] in
            try? await manager.deliver(notification)
        }
    }
}
