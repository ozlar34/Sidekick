import AppKit

// IN-07: AppDelegate is now @MainActor-isolated (so PanelController's
// @MainActor-isolation composes correctly). Top-level main.swift statements
// run in a nonisolated context, but at process startup we are already on the
// main thread. `MainActor.assumeIsolated` records that fact and lets us
// construct and wire the delegate without an async hop.
MainActor.assumeIsolated {
    // Register bundled Josefin Sans before NSApplication boots so every
    // view's first font resolution finds the family. Info.plist's
    // ATSApplicationFontsPath also registers, but calling here covers
    // `swift run` dev builds that run without a bundle.
    SidekickFont.register()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
