import XCTest
@testable import Sidekick

/// The welcome window shows to a new install once, and not to an install that was used before or already saw it.
final class FirstRunTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "FirstRunTests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func test_newInstall_shows() {
        XCTAssertTrue(FirstRun.shouldShow(defaults: defaults))
    }

    func test_afterMarkSeen_doesNotShowAgain() {
        FirstRun.markSeen(defaults: defaults)
        XCTAssertFalse(FirstRun.shouldShow(defaults: defaults))
    }

    func test_installUsedBeforeTheWelcomeExisted_doesNotShow() {
        defaults.set(480.0, forKey: Defaults.panelWidth)
        XCTAssertFalse(FirstRun.shouldShow(defaults: defaults))
    }

    func test_installWithASelectedNote_doesNotShow() {
        defaults.set("a.md", forKey: Defaults.lastSelectedNoteFilename)
        XCTAssertFalse(FirstRun.shouldShow(defaults: defaults))
    }
}
