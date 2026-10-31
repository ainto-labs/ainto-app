import AppKit

/// System tray (menu bar) icon manager.
@MainActor
final class TrayManager: NSObject {
    private var statusItem: NSStatusItem?
    private let onSettings: @MainActor () -> Void
    private let onShowUpdate: @MainActor () -> Void
    private weak var hotkeyManager: HotkeyManager?
    private let hotkeySubmenu = NSMenu()
    private let updateItem = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
    private let updateSeparator = NSMenuItem.separator()
    private let updateBadge = NSView()

    init(
        hotkeyManager: HotkeyManager?,
        onSettings: @escaping @MainActor () -> Void,
        onShowUpdate: @escaping @MainActor () -> Void
    ) {
        self.hotkeyManager = hotkeyManager
        self.onSettings = onSettings
        self.onShowUpdate = onShowUpdate
        super.init()
        setupTray()
        setPendingUpdate(nil)
    }

    func setPendingUpdate(_ version: String?) {
        if let version {
            updateItem.title = "Update to Ainto \(version)…"
        }
        updateItem.isHidden = version == nil
        updateSeparator.isHidden = version == nil
        updateBadge.isHidden = version == nil

        let description = version.map { "Ainto, update \($0) available" } ?? "Ainto"
        statusItem?.button?.toolTip = version == nil ? nil : description
        statusItem?.button?.setAccessibilityLabel(description)
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
            addUpdateBadge(to: button)
        }

        let menu = NSMenu()
        menu.delegate = self

        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(updateSeparator)

        // Hotkey submenu
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
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

    /// A dot over the icon's corner. Drawn as a subview so the icon itself
    /// stays a template image that adapts to light and dark menu bars.
    private func addUpdateBadge(to button: NSStatusBarButton) {
        updateBadge.wantsLayer = true
        updateBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        updateBadge.layer?.cornerRadius = 3
        updateBadge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(updateBadge)
        NSLayoutConstraint.activate([
            updateBadge.widthAnchor.constraint(equalToConstant: 6),
            updateBadge.heightAnchor.constraint(equalToConstant: 6),
            updateBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
            updateBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
        ])
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func showUpdate() {
        onShowUpdate()
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        guard let displayName = sender.representedObject as? String else { return }
        hotkeyManager?.setHotkey(displayName)
    }

    private func loadMenuBarIcon() -> NSImage? {
        // Xcode collapses ainto-menubar.png + @2x + @3x into a single
        // multi-rep ainto-menubar.tiff. SPM keeps them as separate PNGs.
        // Either way we want a single NSImage with all reps so macOS
        // picks the right pixel density for the current display.
        if let url = ResourceBundle.url(forResource: "ainto-menubar", withExtension: "tiff"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            return image
        }
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
        let current = hotkeyManager?.currentHotkey ?? ""
        for item in hotkeySubmenu.items {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }
}
