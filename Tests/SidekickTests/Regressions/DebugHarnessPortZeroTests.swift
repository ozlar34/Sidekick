import XCTest
import Network
@testable import Sidekick

// Why this file lives in Regressions/:
// Live verification (2026-09-03): `--debug-port 0` silently bound an ephemeral
// port. `NWEndpoint.Port(rawValue: 0)` is not nil — it is the "any" port — so
// the failable-initializer guard in `DebugHarness.start` never fires for 0.
// Contract pinned here: port 0 is rejected before a listener is constructed.
@MainActor
final class DebugHarnessPortZeroTests: XCTestCase {

    func test_startWithPortZero_doesNotCreateListener() {
        let delegate = AppDelegate()
        let harness = DebugHarness(app: delegate)
        harness.start(port: 0)
        XCTAssertNil(harness.listener, "--debug-port 0 must not bind an ephemeral port")
    }
}
