import XCTest
import AppKit
@testable import Sidekick

/// Command-Shift-X must reach Format > Strikethrough, not Edit > Cut (also `x`; Edit comes first in
/// the menu). A real key event goes through the app's real main menu (`installMainMenu`), with no direct offer to the
/// Format submenu. A test run has no key window, so the menu's items are pointed at a recorder: AppKit still does the
/// matching of the key event to an item, the recorder only says which item it picked.
@MainActor
final class MenuShiftXRoutingTests: XCTestCase {

    @MainActor private final class Recorder: NSObject {
        var hits: [String] = []
        @objc func hit(_ item: NSMenuItem) { hits.append(item.title) }
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
    }

    private var delegate: AppDelegate!
    private let recorder = Recorder()

    override func setUp() async throws {
        _ = NSApplication.shared
        delegate = AppDelegate()
        delegate.installMainMenu()
        func rewire(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { rewire(sub) } else if !item.keyEquivalent.isEmpty {
                    item.target = recorder; item.action = #selector(Recorder.hit(_:))
                }
            }
        }
        rewire(NSApp.mainMenu!)
    }

    /// The item the real main menu picks for Command (+ Shift) and `chars`.
    private func picked(_ chars: String, code: UInt16, shift: Bool) -> String? {
        recorder.hits = []
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : [.command],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                     characters: shift ? chars.uppercased() : chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
        XCTAssertEqual(NSApp.mainMenu!.performKeyEquivalent(with: event), !recorder.hits.isEmpty)
        return recorder.hits.last
    }

    func testCommandShiftXIsStrikethroughAndCommandXIsCut() {
        XCTAssertEqual(picked("x", code: 7, shift: true), "Strikethrough")
        XCTAssertEqual(picked("x", code: 7, shift: false), "Cut")
    }

    /// The other Edit items and their Shift variants keep their own meaning.
    func testShiftVariantsOfOtherEditItems() {
        XCTAssertEqual(picked("z", code: 6, shift: false), "Undo")
        XCTAssertEqual(picked("v", code: 9, shift: false), "Paste")
        XCTAssertEqual(picked("c", code: 8, shift: false), "Copy")
        XCTAssertEqual(picked("a", code: 0, shift: false), "Select All")
        XCTAssertEqual(picked("b", code: 11, shift: false), "Bold")
        // Shift variants with no menu item of their own must not run the plain Edit item.
        for (c, code, plain) in [("v", UInt16(9), "Paste"), ("c", UInt16(8), "Copy"), ("a", UInt16(0), "Select All")] {
            XCTAssertNotEqual(picked(c, code: code, shift: true), plain, "Command-Shift-\(c) must not run \(plain)")
        }
    }
}
