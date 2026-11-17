/// Settings form — five rows: Global Shortcut, Notes Folder, Panel Width, Show in Dock, Launch at Login.
///
/// Pattern sources:
///   - CONTEXT.md: S-03 (five-row flat form), S-05 (conflict warning), LL-01 (SMAppService)
///   - UI-SPEC.md: Copywriting Contract + Settings Window interaction contract
///   - RESEARCH.md §Pattern 2 (SMAppService), §Pattern 1 (KeyboardShortcuts)
///   - REQUIREMENTS.md: HOTKEY-06 (conflict warning)
///   - SidebarView.swift (analog — top-level SwiftUI view with @AppStorage)
import SwiftUI
import KeyboardShortcuts
import ServiceManagement
import AppKit
import Carbon.HIToolbox

// HOTKEY-06: Check whether a shortcut matches any system-reserved hotkey using Carbon CopySymbolicHotKeys.
// KeyboardShortcuts.Shortcut.isTakenBySystem is internal; replicate the check here using the same Carbon API.
// Carbon modifier mask bits (from HIToolbox/Events.h): cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096.
// We normalize by masking to just these four bits so minor variant bits don't cause false negatives.
private let carbonModifierMask: Int = cmdKey | shiftKey | optionKey | controlKey

private func isShortcutTakenBySystem(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
    var shortcutsUnmanaged: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&shortcutsUnmanaged) == noErr,
          let shortcuts = shortcutsUnmanaged?.takeRetainedValue() as? [[String: Any]] else {
        return false
    }
    let shortcutMods = shortcut.carbonModifiers & carbonModifierMask
    return shortcuts.contains { dict in
        guard
            let enabled = dict[kHISymbolicHotKeyEnabled as String] as? Bool, enabled,
            let keyCode = dict[kHISymbolicHotKeyCode as String] as? Int,
            let modifiers = dict[kHISymbolicHotKeyModifiers as String] as? Int
        else { return false }
        return keyCode == shortcut.carbonKeyCode && (modifiers & carbonModifierMask) == shortcutMods
    }
}

struct SettingsView: View {
    @AppStorage(Defaults.notesFolder, store: Defaults.store) private var notesFolder: String = ""
    @AppStorage(Defaults.panelWidth) private var panelWidth: Double = Double(PanelSizes.defaultPanelWidth)
    @AppStorage(Defaults.showInDock) private var showInDock: Bool = true
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    // HOTKEY-06: Conflict detection state.
    @State private var conflictAppName: String? = nil
    @State private var previousShortcut: KeyboardShortcuts.Shortcut? = nil

    var body: some View {
        Form {
            LabeledContent("Global Shortcut") {
                VStack(alignment: .leading, spacing: 4) {
                    KeyboardShortcuts.Recorder(for: .togglePanel, onChange: { newShortcut in
                        handleShortcutChange(newShortcut)
                    })
                    if let app = conflictAppName {
                        Text("⚠ Already used by \(app)")
                            .font(.system(size: 11))
                            .foregroundColor(Color(.systemRed))
                    }
                }
            }
            LabeledContent("Notes Folder") {
                HStack {
                    Text(displayPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Browse...") { browseFolder() }.buttonStyle(.bordered)
                }
            }
            LabeledContent("Panel Width") {
                PanelWidthField(width: $panelWidth)
            }
            Toggle("Show in Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, newValue in
                    applyDockVisibility(newValue)
                }
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .frame(width: 400)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            previousShortcut = KeyboardShortcuts.getShortcut(for: .togglePanel)
        }
    }

    // HOTKEY-06: handle shortcut change; if system-taken, revert and surface warning.
    private func handleShortcutChange(_ newShortcut: KeyboardShortcuts.Shortcut?) {
        guard let shortcut = newShortcut else {
            conflictAppName = nil
            previousShortcut = nil
            return
        }
        if isShortcutTakenBySystem(shortcut) {
            // Surface inline warning. Use a generic label; querying
            // NSWorkspace.shared.runningApplications cannot reliably attribute
            // a system shortcut to a specific app.
            conflictAppName = "another app"
            // Revert: restore previous if we have one, else clear.
            if let prev = previousShortcut {
                KeyboardShortcuts.setShortcut(prev, for: .togglePanel)
            } else {
                KeyboardShortcuts.reset(.togglePanel)
            }
            NSLog("[Sidekick] hotkey conflict detected; reverted")
        } else {
            conflictAppName = nil
            previousShortcut = shortcut
        }
    }

    private var displayPath: String {
        notesFolder.isEmpty
            ? StorageLocation.defaultNotesFolder.path
            : notesFolder
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            notesFolder = url.path
            // Take effect now: the running store moves to the new folder (pending saves go to the old one first).
            if let store = (NSApp.delegate as? AppDelegate)?.store {
                Task {
                    do { try await store.applyNotesFolderSetting(url.path) }
                    catch { NSLog("[Sidekick] settings folder rebind failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            NSLog("[Sidekick] Launch at Login set to \(enabled)")
        } catch {
            NSLog("[Sidekick] SMAppService error: \(error.localizedDescription)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func applyDockVisibility(_ show: Bool) {
        // Live effect: if the panel is currently open, apply immediately.
        if let ctrl = (NSApp.delegate as? AppDelegate)?.panelController,
           ctrl.panel?.isVisible == true {
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }
        NSLog("[Sidekick] Show in Dock set to \(show)")
    }
}

/// The Panel Width row. You type freely: the value is kept inside the limits only on Enter or when the field loses
/// focus (clamping on every keystroke turned the "56" of a half-typed "560" into 320). The arrows step 10 pt.
/// A width set by dragging the panel edge shows here too.
private struct PanelWidthField: View {
    @Binding var width: Double
    @State private var draft: Double = 0
    @FocusState private var focused: Bool

    private static let step: Double = 10
    private static let range = Double(PanelSizes.minPanelWidth)...Double(PanelSizes.maxPanelWidth)

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $draft, format: .number)
                .frame(width: 60)
                .focused($focused)
                .onSubmit { apply(draft) }
                .onChange(of: focused) { _, isFocused in if !isFocused { apply(draft) } }
            Stepper("Panel Width", value: Binding(get: { width }, set: { apply($0) }), in: Self.range, step: Self.step)
                .labelsHidden()
            Text("pt (\(Int(Self.range.lowerBound))–\(Int(Self.range.upperBound)))").foregroundStyle(.secondary)
        }
        .onAppear { draft = width }
        .onChange(of: width) { _, newWidth in if !focused { draft = newWidth } }
        .onDisappear { apply(draft) }
    }

    /// Keeps `value` inside the limits, stores it and resizes the panel if it is on screen.
    private func apply(_ value: Double) {
        let clamped = Double(PanelSizes.panelWidth(CGFloat(value)))
        draft = clamped
        guard clamped != width else { return }
        width = clamped
        if let ctrl = (NSApp.delegate as? AppDelegate)?.panelController, ctrl.panel?.isVisible == true {
            ctrl.resizePanel(to: clamped)
        }
    }
}
