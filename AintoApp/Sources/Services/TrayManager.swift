import AppKit

/// System tray (menu bar) icon manager.
/// Single purpose: open Settings.
@MainActor
final class TrayManager {
    private var statusItem: NSStatusItem?
    private let onSettings: @MainActor () -> Void

    init(onSettings: @escaping @MainActor () -> Void) {
        self.onSettings = onSettings
        setupTray()
    }

    private func setupTray() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let icon = loadMenuBarIcon() {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Ainto")
            }
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.items.first?.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Ainto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        onSettings()
    }

    private func loadMenuBarIcon() -> NSImage? {
        // Xcode may convert PNG to TIFF; try both
        for ext in ["png", "tiff"] {
            if let url = ResourceBundle.url(forResource: "ainto-menubar", withExtension: ext),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }
        return nil
    }
}
