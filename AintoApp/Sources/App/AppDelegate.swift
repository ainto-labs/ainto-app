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

        // Start global text expansion
        textExpander = TextExpander()
        textExpander?.start()

        // Set up tray icon
        trayManager = TrayManager(onSettings: { [weak self] in
            self?.openSettings()
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stopMonitoring()
        textExpander?.stop()
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
        // Initialize clipboard store with default max items
        let _ = rc_clipboard_init(200)

        // Discover apps (without icons — Swift loads icons via NSWorkspace)
        let _ = rc_discover_apps(false)
    }
}
