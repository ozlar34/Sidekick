import XCTest

/// Fails a hung test fast, by name, with the main thread's stack, instead of letting CI sit until its job timeout.
/// A hang cannot be failed from inside the test (the main thread is stuck), so a background timer ends the process.
/// Installed once, from the first `NewEditorHost` of a run (a SwiftPM test bundle has no principal class to do it).
final class TestWatchdog: NSObject, XCTestObservation {
    static let defaultLimit: TimeInterval = Double(ProcessInfo.processInfo.environment["SIDEKICK_TEST_WATCHDOG_SECONDS"] ?? "") ?? 120
    private static var installed = false

    /// Called on the timer queue when a test ran past the limit; the default prints the report and ends the process.
    private let onExpire: (String) -> Void
    private let limit: TimeInterval
    private let queue = DispatchQueue(label: "sidekick.test-watchdog")
    private var timer: DispatchSourceTimer?

    init(limit: TimeInterval = TestWatchdog.defaultLimit, onExpire: @escaping (String) -> Void = TestWatchdog.report) {
        self.limit = limit
        self.onExpire = onExpire
    }

    @MainActor static func installOnce() {
        guard !installed else { return }
        installed = true
        XCTestObservationCenter.shared.addTestObserver(TestWatchdog())
    }

    func testCaseWillStart(_ testCase: XCTestCase) { arm(testCase.name) }
    func testCaseDidFinish(_ testCase: XCTestCase) { disarm() }

    func arm(_ name: String) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + limit)
        t.setEventHandler { [onExpire, limit] in onExpire("\(name) ran longer than \(limit) s") }
        queue.sync { timer?.cancel(); timer = t }
        t.resume()
    }

    func disarm() { queue.sync { timer?.cancel(); timer = nil } }

    /// The failure line, the main thread's stack (`sample`), then exit 1 so the run fails on the spot.
    static func report(_ message: String) {
        FileHandle.standardError.write(Data("\nTEST WATCHDOG: \(message); sampling this process and stopping the run\n".utf8))
        let out = NSTemporaryDirectory() + "sidekick-watchdog-sample.txt"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-file", out]
        if (try? p.run()) != nil {
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            if done.wait(timeout: .now() + 20) == .timedOut { p.terminate() }
            if let text = try? String(contentsOfFile: out, encoding: .utf8) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        }
        _exit(1)
    }
}

final class TestWatchdogTests: XCTestCase {
    func testALongTestIsReportedByNameAndAFinishedOneIsNot() {
        var reports: [String] = []
        let fired = expectation(description: "fires")
        let dog = TestWatchdog(limit: 0.1) { reports.append($0); fired.fulfill() }
        dog.arm("SomeTests.testHang")
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(reports, ["SomeTests.testHang ran longer than 0.1 s"])
        let quiet = TestWatchdog(limit: 0.2) { _ in XCTFail("fired after the test finished") }
        quiet.arm("SomeTests.testFast")
        quiet.disarm()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    }
}
