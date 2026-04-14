@preconcurrency import HotKey
import AppKit
import Carbon

/// Hotkey configuration — maps display string to Key + Modifiers.
struct HotkeyConfig: Sendable {
    let displayName: String
    let key: Key
    let modifiers: NSEvent.ModifierFlags

    static let options: [HotkeyConfig] = [
        HotkeyConfig(displayName: "⌘ ⇧ Space", key: .space, modifiers: [.command, .shift]),
        HotkeyConfig(displayName: "⌘ Space", key: .space, modifiers: [.command]),
        HotkeyConfig(displayName: "⌥ Space", key: .space, modifiers: [.option]),
        HotkeyConfig(displayName: "⌃ Space", key: .space, modifiers: [.control]),
        HotkeyConfig(displayName: "⌘ ⇧ K", key: .k, modifiers: [.command, .shift]),
        HotkeyConfig(displayName: "⌥ ⇧ Space", key: .space, modifiers: [.option, .shift]),
    ]

    static func find(_ displayName: String) -> HotkeyConfig? {
        options.first { $0.displayName == displayName }
    }
}

/// Manages global hotkey registration with dynamic switching.
@MainActor
final class HotkeyManager {
    private var hotKey: HotKey?
    private let onToggle: @MainActor () -> Void
    private(set) var currentHotkey: String = "⌘ ⇧ Space"

    /// Called when hotkey registration fails (e.g., Spotlight occupies Cmd+Space).
    var onRegistrationFailed: ((String) -> Void)?

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
        // Load saved hotkey from config
        let saved = loadSavedHotkey()
        setHotkey(saved)
    }

    /// Change the global hotkey. Returns true if successful.
    @discardableResult
    func setHotkey(_ displayName: String) -> Bool {
        guard let config = HotkeyConfig.find(displayName) else { return false }

        // Unregister old hotkey
        hotKey = nil

        // Register new hotkey
        let newHotKey = HotKey(key: config.key, modifiers: config.modifiers)
        newHotKey.keyUpHandler = { [weak self] in
            Task { @MainActor in
                self?.onToggle()
            }
        }

        hotKey = newHotKey
        currentHotkey = displayName

        // Save to config
        saveHotkey(displayName)

        // Verify it works by checking if the hotkey is actually registered
        // (HotKey library doesn't provide a direct way to check, but if Spotlight
        // has Cmd+Space, our registration silently fails)
        if displayName == "⌘ Space" {
            // Show guidance to disable Spotlight's Cmd+Space
            onRegistrationFailed?(displayName)
        }

        return true
    }

    /// Open System Settings → Keyboard → Keyboard Shortcuts → Spotlight
    static func openSpotlightSettings() {
        // Open Keyboard settings, then guide user to Keyboard Shortcuts → Spotlight
        // Unfortunately there's no deep link directly to the Spotlight shortcuts tab
        let script = """
        tell application "System Settings"
            activate
            reveal anchor "Shortcuts" of pane id "com.apple.Keyboard-Settings.extension"
        end tell
        """
        // Try AppleScript first for deeper navigation
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if error == nil { return }
        }
        // Fallback: open Keyboard settings
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Persistence

    private func loadSavedHotkey() -> String {
        // Read from UserDefaults (simpler than going through Rust config for this)
        UserDefaults.standard.string(forKey: "globalHotkey") ?? "⌘ ⇧ Space"
    }

    private func saveHotkey(_ displayName: String) {
        UserDefaults.standard.set(displayName, forKey: "globalHotkey")
    }
}
