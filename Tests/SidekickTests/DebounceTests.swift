import XCTest
@testable import Sidekick

final class DebounceTests: XCTestCase {

    func testFiresOnceAfterInterval() async throws {
        let debouncer = Debouncer(interval: 0.05)  // 50ms test-friendly
        let counter = Counter()
        await debouncer.schedule { await counter.increment() }
        try await Task.sleep(nanoseconds: 150_000_000)  // 150ms
        let value = await counter.value
        XCTAssertEqual(value, 1)
    }

    func testCancelAndReschedule_OnlyLastRuns() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        await debouncer.schedule { await counter.increment(by: 10) }
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms — well before fire
        await debouncer.schedule { await counter.increment(by: 1) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let value = await counter.value
        XCTAssertEqual(value, 1, "First scheduled work should be cancelled; only second runs")
    }

    func testRapidSchedules_OnlyLastRuns() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        for i in 1...5 {
            await debouncer.schedule { await counter.set(i) }
            try await Task.sleep(nanoseconds: 5_000_000)  // 5ms between schedules
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let value = await counter.value
        XCTAssertEqual(value, 5, "Only the last scheduled work should run")
    }

    func testExplicitCancel_NothingRuns() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        await debouncer.schedule { await counter.increment() }
        await debouncer.cancel()
        try await Task.sleep(nanoseconds: 150_000_000)
        let value = await counter.value
        XCTAssertEqual(value, 0)
    }

    func testFlush_RunsPendingWorkImmediately() async throws {
        let debouncer = Debouncer(interval: 5)  // would never fire on its own in this test
        let counter = Counter()
        await debouncer.schedule { await counter.increment() }
        await debouncer.flush()
        let value = await counter.value
        XCTAssertEqual(value, 1, "flush() must run the pending work and wait for it")
    }

    func testFlush_RunsWorkOnlyOnce() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        await debouncer.schedule { await counter.increment() }
        await debouncer.flush()
        try await Task.sleep(nanoseconds: 150_000_000)  // past the original interval
        let value = await counter.value
        XCTAssertEqual(value, 1, "the cancelled timer must not run the work a second time")
    }

    func testFlush_WithNothingPendingIsNoOp() async throws {
        let debouncer = Debouncer(interval: 0.05)
        let counter = Counter()
        await debouncer.flush()
        await debouncer.schedule { await counter.increment() }
        await debouncer.cancel()
        await debouncer.flush()
        let value = await counter.value
        XCTAssertEqual(value, 0, "a cancelled schedule is not resurrected by flush()")
    }

    // Test helper actor
    actor Counter {
        private(set) var value: Int = 0
        func increment(by n: Int = 1) { value += n }
        func set(_ n: Int) { value = n }
    }
}
