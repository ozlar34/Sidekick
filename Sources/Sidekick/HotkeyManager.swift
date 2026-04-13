import AppKit
import Carbon.HIToolbox

/// Thin wrapper around Carbon's `RegisterEventHotKey` that registers ⌃⌥⌘N
/// globally and dispatches a main-queue callback on press.
///
/// Ported from ~/projects/StandingDeskTimer/Sources/StandingDeskTimer/AppDelegate.swift:128-153
/// with modifiers swapped to ⌃⌥⌘ and the key code swapped to N.
final class HotkeyManager {

    /// Fires on the main queue whenever the registered hotkey is pressed.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Registers ⌃⌥⌘N globally. Safe to call once at launch.
    /// Returns true if `RegisterEventHotKey` succeeded.
    @discardableResult
    func register() -> Bool {
        // ⌃⌥⌘N — CONTEXT.md locks this combo for Phase 1.
        let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_N)

        var hotKeyID = EventHotKeyID()
        // "SIK$" — Sidekick signature, distinct from StandingDeskTimer's "SDT$"
        // so both apps can run side-by-side without Carbon ID collision.
        hotKeyID.signature = OSType(0x53494B24)
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onPress?() }
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("[Sidekick] hotkey registration failed: status=\(status). Likely ⌃⌥⌘N is already claimed.")
            return false
        }
        return true
    }

    /// Unregisters the hotkey and removes the event handler. Call from
    /// `applicationWillTerminate`.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
    }
}
