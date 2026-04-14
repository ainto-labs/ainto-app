import AppKit

/// System tray (menu bar) icon manager.
@MainActor
final class TrayManager: NSObject {
    private var statusItem: NSStatusItem?
    private let onSettings: @MainActor () -> Void
    private weak var hotkeyManager: HotkeyManager?

    init(hotkeyManager: HotkeyManager?, onSettings: @escaping @MainActor () -> Void) {
        self.hotkeyManager = hotkeyManager
        self.onSettings = onSettings
        super.init()
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
        menu.delegate = self

        // Hotkey submenu
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hotkeySubmenu = NSMenu()
        for option in HotkeyConfig.options {
            let item = NSMenuItem(title: option.displayName, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.displayName
            hotkeySubmenu.addItem(item)
        }
        hotkeyItem.submenu = hotkeySubmenu
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Ainto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let displayName = sender.representedObject as? String else { return }
        hotkeyManager?.setHotkey(displayName)
    }

    private func loadMenuBarIcon() -> NSImage? {
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

extension TrayManager: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Update checkmarks on hotkey submenu
        guard let hotkeyItem = menu.items.first,
              let submenu = hotkeyItem.submenu else { return }
        let current = hotkeyManager?.currentHotkey ?? ""
        for item in submenu.items {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }
}
