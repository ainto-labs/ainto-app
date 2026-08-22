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
    /// Watches for files that are created after launch without polling.
    private var configDirectoryWatcher: DispatchSourceFileSystemObject?

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

    private var configDirectory: String { NSHomeDirectory() + "/.config/ainto" }

    /// Monitor the directory so files missing at launch can be watched as soon
    /// as they are created, without waking the app on a polling timer.
    private func watchConfigDirectory() {
        guard configDirectoryWatcher == nil else { return }
        try? FileManager.default.createDirectory(
            atPath: configDirectory,
            withIntermediateDirectories: true
        )
        let fileDescriptor = open(configDirectory, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let activeSource = self.configDirectoryWatcher else { return }
            let events = activeSource.data
            if events.contains(.rename) || events.contains(.delete) {
                activeSource.cancel()
                self.configDirectoryWatcher = nil
                self.configWatchers.values.forEach { $0.cancel() }
                self.configWatchers.removeAll()
                self.watchConfigDirectory()
                return
            }
            for name in Self.watchedConfigFiles where self.configWatchers[name] == nil {
                self.watchConfigFile(named: name, reloadAfterOpening: true)
            }
        }
        source.setCancelHandler { close(fileDescriptor) }
        configDirectoryWatcher = source
        source.resume()

        for name in Self.watchedConfigFiles {
            watchConfigFile(named: name, reloadAfterOpening: false)
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
    private func watchConfigFile(named name: String, reloadAfterOpening: Bool) {
        guard configWatchers[name] == nil else { return }
        let fileDescriptor = open(configDirectory + "/" + name, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let activeSource = self.configWatchers[name] else { return }
            let events = activeSource.data
            self.reloadConfigFile(named: name)
            if events.contains(.rename) || events.contains(.delete) {
                activeSource.cancel()
                self.configWatchers[name] = nil
                // Atomic saves normally leave the replacement at the path by
                // the next main-queue turn. If it is still missing, the
                // directory watcher will install a watcher when it is created.
                DispatchQueue.main.async { [weak self] in
                    self?.watchConfigFile(named: name, reloadAfterOpening: true)
                }
            }
        }
        source.setCancelHandler { close(fileDescriptor) }
        configWatchers[name] = source
        source.resume()
        if reloadAfterOpening {
            reloadConfigFile(named: name)
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
        configDirectoryWatcher?.cancel()
        configDirectoryWatcher = nil
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
