import Foundation

/// One app-wide source for current-user sockets. Switching projects only changes attribution.
actor SharedUserProcessReader {
    private let scanner: any LocalPortScanning
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: SourceReading<[ListeningProcess]>?
    private var flight: (id: UUID, task: Task<SourceReading<[ListeningProcess]>, any Error>, waiters: Set<UUID>)?

    init(scanner: any LocalPortScanning, maximumAge: TimeInterval = 60,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.scanner = scanner
        self.maximumAge = maximumAge
        self.now = now
    }

    var activeReadCount: Int { flight?.waiters.count ?? 0 }

    func read(force: Bool = false) async throws -> SourceReading<[ListeningProcess]> {
        try Task.checkCancellation()
        if !force, let cached, now().timeIntervalSince(cached.attemptedAt) < maximumAge {
            // Reuse the original timestamps and failures; a cache hit is not a new successful scan.
            return cached
        }
        if flight == nil {
            let scanner = scanner
            let now = now
            let previous = cached
            flight = (UUID(), Task {
                do {
                    let processes = try await scanner.scan()
                    try Task.checkCancellation()
                    return .success(processes, at: now())
                } catch is CancellationError { throw CancellationError() }
                catch { return SourceReading<[ListeningProcess]>.failed(error, at: now()).retainingTrustedValue(from: previous) }
            }, [])
        }
        let waiter = UUID()
        flight!.waiters.insert(waiter)
        let current = flight!
        return try await withTaskCancellationHandler {
            do {
                let result = try await current.task.value
                try Task.checkCancellation()
                // All subscribers get the same result, merged once with the last trusted reading.
                if flight?.id == current.id {
                    cached = result
                    flight = nil
                }
                return result
            } catch {
                remove(waiter: waiter, flightID: current.id)
                throw error
            }
        } onCancel: {
            Task { await self.remove(waiter: waiter, flightID: current.id) }
        }
    }

    private func remove(waiter: UUID, flightID: UUID) {
        guard flight?.id == flightID else { return }
        flight?.waiters.remove(waiter)
        if flight?.waiters.isEmpty == true {
            // One cancelled project must not cancel another consumer; cancel the child only when unused.
            flight?.task.cancel()
            flight = nil
        }
    }
}
