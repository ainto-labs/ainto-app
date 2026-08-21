import AppKit
import SwiftUI
import AintoCore
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var searchPanel: SearchPanel?
    private var hotkeyManager: HotkeyManager?
    private var clipboardMonitor: ClipboardMonitor?
    private var textExpander: TextExpander?
    private var trayManager: TrayManager?
    private var settingsWindow: NSWindow?
    /// Live config-file watchers, keyed by file name.
    private var configWatchers: [String: DispatchSourceFileSystemObject] = [:]

    private var updaterController: SPUStandardUpdaterController?

    var updater: SPUUpdater? {
        updaterController?.updater
    }

    /// Only start Sparkle when running as a .app bundle (not bare SPM binary).
    private func setupSparkle() {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (LSUIElement behavior)
        NSApp.setActivationPolicy(.accessory)

        // Prevent macOS from auto-terminating this background launcher
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false

        // Initialize Rust core
        initializeRustCore()

        // Start Sparkle auto-update (only in .app bundle)
        setupSparkle()

        // Set up search panel
        searchPanel = SearchPanel()
        searchPanel?.viewModel.onSnippetsChanged = { [weak self] in
            self?.textExpander?.reloadSnippets()
        }

        // Set up global hotkey
        hotkeyManager = HotkeyManager { [weak self] in
            self?.toggleSearchPanel()
        }
        // Spotlight/Raycast conflict warnings are handled in SettingsView

        // Start clipboard monitoring
        clipboardMonitor = ClipboardMonitor()
        clipboardMonitor?.onClipboardChanged = { [weak self] in
            self?.searchPanel?.viewModel.reloadClipboardIfVisible()
        }
        clipboardMonitor?.startMonitoring()

        // Start global text expansion (only while enabled in config)
        textExpander = TextExpander()
        applySnippetsEnabled()

        // Set up tray icon
        trayManager = TrayManager(hotkeyManager: hotkeyManager, onSettings: { [weak self] in
            self?.openSettings()
        })

        // Watch ~/.config/ainto/ for external file changes (e.g. manual TOML edits)
        watchConfigDirectory()
    }

    private static let watchedConfigFiles = ["snippets.toml", "ai-commands.toml", "config.toml"]

    /// Delay before re-opening a config file that is missing or was replaced.
    /// An atomic save briefly leaves no file at the path, so retry rather than
    /// give up on the first failure.
    private static let configWatchRearmDelay: TimeInterval = 1.0

    private var configDirectory: String { NSHomeDirectory() + "/.config/ainto" }

    /// Monitor config files for external changes and reload automatically.
    private func watchConfigDirectory() {
        for file in Self.watchedConfigFiles {
            watchConfigFile(named: file)
        }
    }

    /// Watch one config file, re-arming whenever the path stops pointing at the
    /// inode we opened.
    ///
    /// A kqueue watcher follows the file descriptor, not the path. Editors save
    /// by writing a temp file and renaming it over the original, which swaps the
    /// inode out — so after a rename or delete the old watcher is live but deaf,
    /// and the path has to be re-opened. The same retry covers a file that does
    /// not exist yet at launch (snippets.toml is only created on first save).
    private func watchConfigFile(named name: String) {
        let fd = open(configDirectory + "/" + name, O_EVTONLY)
        guard fd >= 0 else {
            scheduleConfigWatchRearm(named: name)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.configWatchers[name] else { return }
            let events = source.data
            self.reloadConfigFile(named: name)
            if events.contains(.rename) || events.contains(.delete) {
                source.cancel()
                self.configWatchers[name] = nil
                self.scheduleConfigWatchRearm(named: name)
            }
        }
        source.setCancelHandler { close(fd) }
        configWatchers[name] = source
        source.resume()
    }

    private func scheduleConfigWatchRearm(named name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.configWatchRearmDelay) { [weak self] in
            guard let self, self.configWatchers[name] == nil else { return }
            self.watchConfigFile(named: name)
        }
    }

    private func reloadConfigFile(named name: String) {
        if name == "config.toml" {
            // Covers both the Settings toggle (saved via rc_config_save)
            // and manual TOML edits.
            applySnippetsEnabled()
        } else {
            searchPanel?.viewModel.loadSnippets()
            searchPanel?.viewModel.loadAICommands()
            textExpander?.reloadSnippets()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stopMonitoring()
        textExpander?.stop()
        configWatchers.values.forEach { $0.cancel() }
        configWatchers.removeAll()
    }

    private func toggleSearchPanel() {
        guard let panel = searchPanel else { return }
        if panel.isPanelVisible {
            panel.hidePanel()
        } else {
            panel.showPanel()
        }
    }

    private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(hotkeyManager: hotkeyManager)
        let hostingView = NSHostingView(rootView: settingsView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear

        // Glassmorphism: add visual effect view behind the hosting view
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = visualEffect
        visualEffect.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func initializeRustCore() {
        // Read per-pool limits from config.toml so eviction matches what
        // the user sees in Settings ("Max text items" / "Max image items").
        // Falls back to the same defaults the Settings UI shows.
        let (maxText, maxImage) = loadClipboardLimits()
        let _ = rc_clipboard_init(UInt64(maxText), UInt64(maxImage))

        // Discover apps (without icons — Swift loads icons via NSWorkspace)
        let _ = rc_discover_apps(false)
    }

    /// Start or stop the keystroke event tap to match `snippets_enabled` in
    /// config.toml. Disabling snippets must actually tear down the CGEvent
    /// tap — users expect no keystroke monitoring while the switch is off.
    private func applySnippetsEnabled() {
        if loadSnippetsEnabled() {
            textExpander?.start()
        } else {
            textExpander?.stop()
        }
    }

    private func loadSnippetsEnabled() -> Bool {
        guard let cstr = rc_config_load() else { return true }
        defer { rc_free_string(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }
        return dict["snippets_enabled"] as? Bool ?? true
    }

    private func loadClipboardLimits() -> (text: Int, image: Int) {
        guard let cstr = rc_config_load() else { return (200, 50) }
        defer { rc_free_string(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (200, 50) }
        let text = dict["clipboard_max_items"] as? Int ?? 200
        let image = dict["clipboard_max_image_items"] as? Int ?? 50
        return (text, image)
    }
}
