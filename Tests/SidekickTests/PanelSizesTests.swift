import XCTest
@testable import Sidekick

/// The panel's size rules: a first launch leaves the editor more room than the sidebar, and no drag of either handle
/// can leave the editor less than its minimum width.
final class PanelSizesTests: XCTestCase {

    func test_firstLaunch_editorIsWiderThanTheSidebar() {
        let sidebar = PanelSizes.sidebarWidth(wanted: PanelSizes.defaultSidebarWidth, panelWidth: PanelSizes.defaultPanelWidth)
        XCTAssertEqual(sidebar, PanelSizes.defaultSidebarWidth, "the default sidebar fits the default panel as it is")
        XCTAssertGreaterThan(PanelSizes.defaultPanelWidth - sidebar, sidebar)
    }

    func test_editorKeepsItsMinimumWidth_atEveryPanelAndSidebarWidth() {
        for panel in stride(from: PanelSizes.minPanelWidth, through: PanelSizes.maxPanelWidth, by: 20) {
            for wanted in stride(from: CGFloat(0), through: 600, by: 20) {
                let sidebar = PanelSizes.sidebarWidth(wanted: wanted, panelWidth: panel)
                XCTAssertGreaterThanOrEqual(panel - sidebar, PanelSizes.minEditorWidth, "panel \(panel), wanted sidebar \(wanted)")
                XCTAssertGreaterThanOrEqual(sidebar, PanelSizes.minSidebarWidth)
                XCTAssertLessThanOrEqual(sidebar, PanelSizes.maxSidebarWidth)
            }
        }
    }

    func test_sidebarKeepsTheWantedWidth_whenThePanelHasRoom() {
        XCTAssertEqual(PanelSizes.sidebarWidth(wanted: 206, panelWidth: 560), 206)
        XCTAssertEqual(PanelSizes.sidebarWidth(wanted: 280, panelWidth: 560), 280)
    }

    func test_narrowPanel_takesRoomFromTheSidebar() {
        XCTAssertEqual(PanelSizes.sidebarWidth(wanted: 280, panelWidth: 380), 180)
        XCTAssertEqual(PanelSizes.sidebarWidth(wanted: 280, panelWidth: PanelSizes.minPanelWidth), PanelSizes.minSidebarWidth)
    }

    func test_panelWidth_staysInsideItsLimits() {
        XCTAssertEqual(PanelSizes.panelWidth(100), PanelSizes.minPanelWidth)
        XCTAssertEqual(PanelSizes.panelWidth(900), PanelSizes.maxPanelWidth)
        XCTAssertEqual(PanelSizes.panelWidth(500), 500)
    }

    /// The panel floats: a gap to the right, top and bottom edges of the usable screen area.
    func test_panelFrame_floatsInsideTheVisibleArea() {
        let visible = CGRect(x: 1000, y: 40, width: 1500, height: 900)
        let frame = PanelSizes.panelFrame(width: 480, in: visible)
        let m = PanelSizes.screenMargin
        XCTAssertGreaterThan(m, 0)
        XCTAssertEqual(frame.maxX, visible.maxX - m)
        XCTAssertEqual(frame.minY, visible.minY + m)
        XCTAssertEqual(frame.maxY, visible.maxY - m)
        XCTAssertEqual(frame.width, 480)
    }
}
