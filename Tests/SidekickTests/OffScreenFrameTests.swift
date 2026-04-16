import XCTest
@testable import Sidekick

/// Pins the contract that `PanelController.offScreenFrame(for:)` uses
/// the target screen's PHYSICAL right edge (`frame.maxX`), not the
/// visibleFrame right edge. Task 2 wires the pure helper into the
/// real `offScreenFrame(for:)` body. Until then these tests exercise
/// only the helper.
final class OffScreenFrameTests: XCTestCase {

    func test_offScreenX_returnsInputAsIs() {
        XCTAssertEqual(
            PanelController.offScreenX(targetScreenMaxX: 2560),
            2560,
            "offScreenX must return the target screen's frame.maxX unchanged"
        )
    }

    func test_offScreenX_allowsNegativeCoordinates() {
        // External monitors placed to the LEFT of primary report negative
        // global coordinates on macOS. No clamping allowed.
        XCTAssertEqual(
            PanelController.offScreenX(targetScreenMaxX: -100),
            -100,
            "Negative target screen maxX (left-placed external display) must pass through"
        )
    }

    func test_offScreenX_singleMonitorSanity() {
        XCTAssertEqual(
            PanelController.offScreenX(targetScreenMaxX: 1440),
            1440,
            "Single-monitor case: offScreenX equals the primary screen maxX"
        )
    }
}
