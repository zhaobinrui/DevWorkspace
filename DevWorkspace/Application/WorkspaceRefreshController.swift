import Foundation
import Observation
import os

enum WorkspaceRefreshVisibility: String, Equatable, Sendable {
    case visible
    case background
}

enum WorkspaceRefreshCondition: Equatable, Sendable {
    case stable
    case transient
    case problem
}

struct WorkspaceRefreshPolicy: Equatable, Sendable {
    var visibleStableInterval: TimeInterval = 60
    var visibleTransientInterval: TimeInterval = 5
    var visibleProblemInterval: TimeInterval = 30
    var backgroundStableInterval: TimeInterval = 300
    var backgroundTransientInterval: TimeInterval = 30
    var backgroundProblemInterval: TimeInterval = 120

    func interval(
        for state: WorkspaceStore.State,
        visibility: WorkspaceRefreshVisibility
    ) -> TimeInterval {
        let condition = condition(for: state)

        return switch (visibility, condition) {
        case (.visible, .stable):
            visibleStableInterval
        case (.visible, .transient):
            visibleTransientInterval
        case (.visible, .problem):
            visibleProblemInterval
        case (.background, .stable):
            backgroundStableInterval
        case (.background, .transient):
            backgroundTransientInterval
        case (.background, .problem):
            backgroundProblemInterval
        }
    }

    func condition(
        for state: WorkspaceStore.State
    ) -> WorkspaceRefreshCondition {
        switch state {
        case .idle, .degraded, .failed:
            .problem
        case .refreshing:
            .transient
        case let .ready(snapshot):
            switch snapshot.lifecycle {
            case .stopped, .ready, .observed:
                .stable
            case .starting:
                .transient
            case .degraded, .failed:
                .problem
            }
        }
    }
}

struct WorkspaceRefreshMetrics: Equatable, Sendable {
    fileprivate(set) var completedRefreshCount = 0
    fileprivate(set) var cancelledRefreshCount = 0
    fileprivate(set) var scheduledWakeCount = 0
    fileprivate(set) var totalRefreshDuration: TimeInterval = 0
    fileprivate(set) var lastRefreshDuration: TimeInterval?
    fileprivate(set) var lastRefreshAt: Date?
    fileprivate(set) var nextRefreshAt: Date?
    fileprivate(set) var scheduledInterval: TimeInterval?

    var averageRefreshDuration: TimeInterval? {
        guard completedRefreshCount > 0 else {
            return nil
        }
        return totalRefreshDuration / Double(completedRefreshCount)
    }
}

@MainActor
@Observable
final class WorkspaceRefreshController {
    private enum Trigger: String {
        case initial
        case scheduled
        case userInitiated
        case becameVisible
    }

    private static let logger = Logger(
        subsystem: DevSpaceProduct.workspace.bundleIdentifier,
        category: "WorkspaceRefresh"
    )
    private static let signpostLog = OSLog(
        subsystem: DevSpaceProduct.workspace.bundleIdentifier,
        category: "WorkspaceRefresh"
    )

    private let store: WorkspaceStore
    let policy: WorkspaceRefreshPolicy

    private(set) var visibility: WorkspaceRefreshVisibility = .background
    private(set) var metrics = WorkspaceRefreshMetrics()
    private(set) var isRunning = false

    @ObservationIgnored
    private var schedulingTask: Task<Void, Never>?

    init(
        store: WorkspaceStore,
        policy: WorkspaceRefreshPolicy = WorkspaceRefreshPolicy()
    ) {
        self.store = store
        self.policy = policy
    }

    func start() {
        guard !isRunning, store.project != nil else {
            return
        }
        isRunning = true
        scheduleLoop(
            refreshImmediately: store.shouldLoad,
            trigger: .initial
        )
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        schedulingTask?.cancel()
        schedulingTask = nil
        clearNextSchedule()
    }

    func setVisible(_ isVisible: Bool) {
        let newVisibility: WorkspaceRefreshVisibility = isVisible
            ? .visible
            : .background
        guard visibility != newVisibility else {
            return
        }

        visibility = newVisibility
        guard isRunning, !store.isRefreshing else {
            return
        }

        let refreshImmediately = isVisible && refreshIsDueForVisibleSurface
        scheduleLoop(
            refreshImmediately: refreshImmediately,
            trigger: refreshImmediately ? .becameVisible : .scheduled
        )
    }

    func refreshNow() async {
        guard !store.isRefreshing else {
            return
        }

        schedulingTask?.cancel()
        schedulingTask = nil
        clearNextSchedule()
        await performRefresh(trigger: .userInitiated)

        if isRunning {
            scheduleLoop(refreshImmediately: false, trigger: .scheduled)
        }
    }

    private var refreshIsDueForVisibleSurface: Bool {
        guard let lastRefreshAt = metrics.lastRefreshAt else {
            return true
        }

        let interval = policy.interval(
            for: store.state,
            visibility: .visible
        )
        return Date().timeIntervalSince(lastRefreshAt) >= interval
    }

    private func scheduleLoop(
        refreshImmediately: Bool,
        trigger: Trigger
    ) {
        schedulingTask?.cancel()
        schedulingTask = Task { [weak self] in
            guard let self else {
                return
            }

            if refreshImmediately {
                await self.performRefresh(trigger: trigger)
            }

            await self.runScheduledLoop()
        }
    }

    private func runScheduledLoop() async {
        while isRunning, !Task.isCancelled {
            let interval = max(
                policy.interval(for: store.state, visibility: visibility),
                0.01
            )
            metrics.scheduledInterval = interval
            metrics.nextRefreshAt = Date().addingTimeInterval(interval)

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }

            guard isRunning, !Task.isCancelled else {
                return
            }
            metrics.scheduledWakeCount += 1
            await performRefresh(trigger: .scheduled)
        }
    }

    private func performRefresh(trigger: Trigger) async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "Workspace Refresh",
            signpostID: signpostID
        )

        await store.refresh(forceProcessRefresh: trigger == .userInitiated || trigger == .scheduled)
        if !Task.isCancelled { await store.refreshHomebrewServices() }

        let elapsed = startedAt.duration(to: clock.now)
        let duration = elapsed.timeInterval
        os_signpost(
            .end,
            log: Self.signpostLog,
            name: "Workspace Refresh",
            signpostID: signpostID
        )

        if Task.isCancelled {
            metrics.cancelledRefreshCount += 1
            Self.logger.debug(
                "Workspace refresh cancelled; trigger=\(trigger.rawValue, privacy: .public)"
            )
            return
        }

        metrics.completedRefreshCount += 1
        metrics.totalRefreshDuration += duration
        metrics.lastRefreshDuration = duration
        metrics.lastRefreshAt = Date()
        Self.logger.debug(
            "Workspace refresh completed; trigger=\(trigger.rawValue, privacy: .public), duration_ms=\(duration * 1_000, privacy: .public)"
        )
    }

    private func clearNextSchedule() {
        metrics.nextRefreshAt = nil
        metrics.scheduledInterval = nil
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
