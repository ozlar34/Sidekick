import Foundation

/// The switch for the new editor view. On by default (ticket 17); with it off the app uses the old
/// editor, which stays in the code until ticket 18. Off when the process is launched with
/// `--old-editor`, or when the hidden default `newEditorEnabled` is false in the shared defaults
/// suite (`defaults write com.oguzoral.Sidekick.shared newEditorEnabled -bool false`).
/// `--new-editor` forces it on over a stored off. `--old-editor` wins over everything.
enum NewEditorSwitch {
    static let launchArgument = "--new-editor"
    static let offLaunchArgument = "--old-editor"
    static let defaultsKey = "newEditorEnabled"

    /// Tests of the old editor's mount path set this to false (and put it back to nil); the app never sets it.
    nonisolated(unsafe) static var testOverride: Bool?

    static var isOn: Bool {
        if let testOverride { return testOverride }
        return isOn(arguments: ProcessInfo.processInfo.arguments, defaults: Defaults.store)
    }

    static func isOn(arguments: [String], defaults: UserDefaults) -> Bool {
        if arguments.contains(offLaunchArgument) { return false }
        if arguments.contains(launchArgument) { return true }
        return (defaults.object(forKey: defaultsKey) as? Bool) ?? true
    }
}
