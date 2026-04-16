/// Global hotkey registration wrapping the KeyboardShortcuts library.
///
/// Pattern sources:
///   - RESEARCH.md §Pattern 1 (KeyboardShortcuts Integration)
///   - CONTEXT.md: S-04 (replace Carbon with KeyboardShortcuts)
///   - HotkeyManager.swift (self-analog — public shape preserved so AppDelegate compiles unchanged)
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePanel = Self(
        "togglePanel",
        default: .init(.n, modifiers: [.control, .option, .command])
    )
}

final class HotkeyManager {

    /// Fires whenever the registered hotkey is pressed.
    var onPress: (() -> Void)?

    /// Registers the togglePanel hotkey via KeyboardShortcuts library.
    /// Safe to call once at launch. Returns true always (KeyboardShortcuts manages registration internally).
    @discardableResult
    func register() -> Bool {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.onPress?()
        }
        NSLog("[Sidekick] hotkey registered via KeyboardShortcuts")
        return true
    }

    /// Unregisters all KeyboardShortcuts handlers. Call from `applicationWillTerminate`.
    func unregister() {
        KeyboardShortcuts.removeAllHandlers()
    }
}
