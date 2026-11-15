import Foundation

/// The switch for the new editor view. Off by default; with it off the app uses the old editor.
/// On when the process is launched with `--new-editor`, or when the hidden default
/// `newEditorEnabled` is true in the shared defaults suite
/// (`defaults write com.oguzoral.Sidekick.shared newEditorEnabled -bool true`).
enum NewEditorSwitch {
    static let launchArgument = "--new-editor"
    static let defaultsKey = "newEditorEnabled"

    static var isOn: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument) || Defaults.store.bool(forKey: defaultsKey)
    }
}
