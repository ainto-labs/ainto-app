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
        // Register 1x/@2x/@3x reps on a single NSImage so macOS picks the
        // right pixel density for the current display. Otherwise the 1x
        // raster gets upscaled on Retina and looks blurry.
        let image = NSImage(size: NSSize(width: 18, height: 18))
        var added = false
        for name in ["ainto-menubar", "ainto-menubar@2x", "ainto-menubar@3x"] {
            guard let url = ResourceBundle.url(forResource: name, withExtension: "png"),
                  let reps = NSImageRep.imageReps(withContentsOf: url) else { continue }
            for rep in reps {
                rep.size = NSSize(width: 18, height: 18)
                image.addRepresentation(rep)
                added = true
            }
        }
        return added ? image : nil
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
