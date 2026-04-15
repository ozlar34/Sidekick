import Foundation

/// Cancel-and-reschedule debouncer using Swift Concurrency. After calling
/// `schedule(_:)`, any previously scheduled-but-not-yet-fired work is
/// cancelled and a new Task is started that sleeps `interval` seconds
/// then runs the work. Used by EditorPaneView for 500ms auto-save debounce.
actor Debouncer {
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func schedule(_ work: @Sendable @escaping () async -> Void) {
        task?.cancel()
        task = Task { [interval] in
            let nanos = UInt64(interval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
