import Foundation

/// Cancel-and-reschedule debouncer using Swift Concurrency. After calling
/// `schedule(_:)`, any previously scheduled-but-not-yet-fired work is
/// replaced and a new Task is started that sleeps `interval` seconds
/// then runs the work. Used for the 500ms auto-save debounce.
///
/// `flush()` runs the pending work immediately instead of waiting out the
/// interval (note switch, app quit) so a scheduled save is never dropped.
actor Debouncer {
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var pending: (@Sendable () async -> Void)?
    private var inFlight: Task<Void, Never>?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func schedule(_ work: @Sendable @escaping () async -> Void) {
        task?.cancel()
        pending = work
        task = Task { [interval] in
            let nanos = UInt64(interval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self.fire()
        }
    }

    /// Runs the pending work now (if any) and returns once it has finished,
    /// including any save that was already in flight.
    func flush() async {
        task?.cancel()
        task = nil
        await fire()
        await inFlight?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private func fire() async {
        // Serialise with a run already in flight so an older save can never
        // land after a newer one.
        await inFlight?.value
        guard let work = pending else { return }
        pending = nil
        task = nil
        let run = Task { await work() }
        inFlight = run
        await run.value
    }
}
