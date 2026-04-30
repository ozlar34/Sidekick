import AppKit

// IN-07: AppDelegate is now @MainActor-isolated (so PanelController's
// @MainActor-isolation composes correctly). Top-level main.swift statements
// run in a nonisolated context, but at process startup we are already on the
// main thread. `MainActor.assumeIsolated` records that fact and lets us
// construct and wire the delegate without an async hop.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
