import SwiftUI
import AppKit
import AintoCore
import ServiceManagement
import Sparkle

/// Settings — clean sidebar + card-based content.
struct SettingsView: View {
    var hotkeyManager: HotkeyManager?

    @State private var clipboardMaxItems: Int = 200
    @State private var clipboardMaxImageItems: Int = 50
    @State private var clipboardImagePath: String = "~/.config/ainto/clipboard"
    @State private var debounceDelay: Int = 300
    @State private var claudeBinary: String = "claude"
    @State private var claudeEnabled: Bool = true
    @State private var snippetsEnabled: Bool = true
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var selectedHotkey: String = "⌘ ⇧ Space"
    @State private var hasLoaded = false
    @State private var selectedSection: SettingsSection = .general
    @State private var showResetConfirm = false
    @State private var raycastRunning = false

    enum SettingsSection: String, CaseIterable {
        case general = "General"
        case clipboard = "Clipboard"
        case claude = "Claude Code"
        case snippets = "Snippets"
        case data = "Data"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .clipboard: return "doc.on.clipboard"
            case .claude: return "sparkle"
            case .snippets: return "text.quote"
            case .data: return "folder"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — darker background
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    if section == .claude {
                        SidebarItemCustomIcon(
                            title: section.rawValue,
                            icon: { ClaudeIcon(size: 14) },
                            isSelected: selectedSection == section
                        )
                        .onTapGesture { selectedSection = section }
                    } else {
                        SidebarItem(
                            title: section.rawValue,
                            icon: section.icon,
                            isSelected: selectedSection == section
                        )
                        .onTapGesture { selectedSection = section }
                    }
                }
                Spacer()
            }
            .frame(width: 160)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedSection {
                    case .general: generalSection
                    case .clipboard: clipboardSection
                    case .claude: claudeSection
                    case .snippets: snippetsSection
                    case .data: dataSection
                    case .about: aboutSection
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 480)
        .onAppear {
            loadConfig()
            if let hk = hotkeyManager?.currentHotkey { selectedHotkey = hk }
            raycastRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.raycast.macos" }
        }
        .onChange(of: clipboardMaxItems) { _, _ in saveConfig() }
        .onChange(of: clipboardMaxImageItems) { _, _ in saveConfig() }
        .onChange(of: debounceDelay) { _, _ in saveConfig() }
        .onChange(of: claudeBinary) { _, _ in saveConfig() }
        .onChange(of: claudeEnabled) { _, _ in saveConfig() }
        .onChange(of: snippetsEnabled) { _, _ in saveConfig() }
        .alert("Reset Rankings", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                let path = ("~/.config/ainto/ranking.toml" as NSString).expandingTildeInPath
                try? FileManager.default.removeItem(atPath: path)
            }
        } message: {
            Text("This will reset all app and command usage rankings. This cannot be undone.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "General", icon: "gearshape")

            SettingsCard {
                VStack(spacing: 16) {
                    SettingsRow(label: "Hotkey") {
                        HotkeyPicker(selected: $selectedHotkey) { newValue in
                            hotkeyManager?.setHotkey(newValue)
                        }
                    }

                    // Spotlight warning — only if Spotlight's Cmd+Space is enabled
                    if selectedHotkey == "⌘ Space" && isSpotlightHotkeyEnabled() {
                        SettingsHint(icon: "exclamationmark.triangle.fill", color: .orange,
                                     text: "Uncheck \"Show Spotlight search\" in Keyboard → Keyboard Shortcuts → Spotlight.") {
                            HotkeyManager.openSpotlightSettings()
                        }
                    }

                    if isRaycastConflicting() {
                        SettingsHint(icon: "exclamationmark.triangle.fill", color: .orange,
                                     text: "Raycast is using the same hotkey (\(getRaycastHotkey() ?? "")). Quit Raycast or choose a different hotkey.") {
                            if let raycast = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.raycast.macos" }) {
                                raycast.terminate()
                                raycastRunning = false
                            }
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Search debounce") {
                        HStack(spacing: 6) {
                            Text("\(debounceDelay) ms")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Stepper("", value: $debounceDelay, in: 100...1000, step: 50)
                                .labelsHidden()
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Launch at login") {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
            }

            Text("Debounce delay before file search triggers after typing stops.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Clipboard", icon: "doc.on.clipboard")

            SettingsCard {
                VStack(spacing: 16) {
                    SettingsRow(label: "Max text items") {
                        HStack(spacing: 6) {
                            Text("\(clipboardMaxItems)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Stepper("", value: $clipboardMaxItems, in: 10...1000, step: 10)
                                .labelsHidden()
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Max image items") {
                        HStack(spacing: 6) {
                            Text("\(clipboardMaxImageItems)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Stepper("", value: $clipboardMaxImageItems, in: 5...200, step: 5)
                                .labelsHidden()
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Image storage") {
                        TextField("", text: $clipboardImagePath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 220)
                    }
                }
            }

            Text("Images are stored as compressed PNG files. Older items are automatically removed when limits are reached.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    // MARK: - Claude

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                ClaudeIcon(size: 18)
                Text("Claude Code")
                    .font(.system(size: 18, weight: .semibold))
            }

            SettingsCard {
                VStack(spacing: 16) {
                    SettingsRow(label: "Enabled") {
                        Toggle("", isOn: $claudeEnabled).labelsHidden().toggleStyle(.switch)
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Binary path") {
                        TextField("claude", text: $claudeBinary)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 220)
                    }
                }
            }

            Text("Press Tab in the launcher to switch to Claude mode.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            // AI Commands subsection
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("AI Commands")
                    .font(.system(size: 15, weight: .medium))
            }
            .padding(.top, 8)

            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai-commands.toml")
                            .font(.system(size: 13))
                        Text("Add, remove, or modify AI commands")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Edit") {
                        let _ = rc_ai_commands_load()
                        let path = ("~/.config/ainto/ai-commands.toml" as NSString).expandingTildeInPath
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                }
            }

            Text("Use {selection} as placeholder for selected text in prompts.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    // MARK: - Snippets

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Snippets", icon: "text.quote")

            SettingsCard {
                VStack(spacing: 16) {
                    SettingsRow(label: "Text expansion") {
                        Toggle("", isOn: $snippetsEnabled).labelsHidden().toggleStyle(.switch)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("snippets.toml")
                                .font(.system(size: 13))
                            Text("Manage snippet keywords and expansions")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Edit") {
                            let path = ("~/.config/ainto/snippets.toml" as NSString).expandingTildeInPath
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    }
                }
            }

            Text("Snippets expand automatically when you type their keyword in any app. Requires Accessibility permission.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Data", icon: "folder")

            SettingsCard {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Config directory")
                                .font(.system(size: 13))
                            Text("~/.config/ainto/")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Open") {
                            let path = ("~/.config/ainto" as NSString).expandingTildeInPath
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Usage rankings")
                                .font(.system(size: 13))
                            Text("Frecency data for apps and commands")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Reset") {
                            showResetConfirm = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(spacing: 20) {
            Spacer()

            AintoAboutIcon(size: 64)

            Text("Ainto")
                .font(.system(size: 22, weight: .bold))

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? appVersion)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("A personal macOS launcher\nbuilt with Swift + Rust")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 12)

            HStack(spacing: 12) {
                AboutButton(title: "Star on GitHub", icon: "star") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ainto-labs/ainto-app")!)
                }
                AboutButton(title: "Report Issue", icon: "exclamationmark.bubble") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ainto-labs/ainto-app/issues")!)
                }
            }

            HStack(spacing: 12) {
                AboutButton(title: "ainto.app", icon: "globe") {
                    NSWorkspace.shared.open(URL(string: "https://ainto.app")!)
                }
                AboutButton(title: "Check for Updates", icon: "arrow.triangle.2.circlepath") {
                    (NSApp.delegate as? AppDelegate)?.updater?.checkForUpdates()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - System Detection

    /// Check if Spotlight's Cmd+Space shortcut is enabled (key 64 in symbolic hotkeys).
    private func isSpotlightHotkeyEnabled() -> Bool {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotkeys["64"] as? [String: Any],
              let enabled = entry["enabled"] as? Bool else {
            return true // assume enabled if can't read
        }
        return enabled
    }

    /// Get Raycast's global hotkey as display string, or nil if not installed/readable.
    private func getRaycastHotkey() -> String? {
        guard let raw = UserDefaults(suiteName: "com.raycast.macos")?
                .string(forKey: "raycastGlobalHotkey") else { return nil }
        // Format: "Command-49" → "⌘ Space", "Command-Shift-49" → "⌘ ⇧ Space"
        return parseRaycastHotkey(raw)
    }

    /// Check if Raycast is running AND its hotkey conflicts with ours.
    private func isRaycastConflicting() -> Bool {
        guard raycastRunning else { return false }
        guard let raycastHotkey = getRaycastHotkey() else { return false }
        return raycastHotkey == selectedHotkey
    }

    /// Parse Raycast's hotkey format to our display format.
    /// "Command-49" → "⌘ Space", "Command-Shift-49" → "⌘ ⇧ Space"
    private func parseRaycastHotkey(_ raw: String) -> String? {
        let parts = raw.split(separator: "-")
        var modifiers: [String] = []
        var keyCode: Int?

        for part in parts {
            switch part {
            case "Command": modifiers.append("⌘")
            case "Shift": modifiers.append("⇧")
            case "Option": modifiers.append("⌥")
            case "Control": modifiers.append("⌃")
            default:
                keyCode = Int(part)
            }
        }

        let keyName: String
        switch keyCode {
        case 49: keyName = "Space"
        case 40: keyName = "K"
        default: return nil
        }

        return (modifiers + [keyName]).joined(separator: " ")
    }

    // MARK: - Config IO

    private func loadConfig() {
        guard let cStr = rc_config_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        clipboardMaxItems = config["clipboard_max_items"] as? Int ?? 200
        clipboardMaxImageItems = config["clipboard_max_image_items"] as? Int ?? 50
        debounceDelay = config["debounce_delay"] as? Int ?? 300
        claudeBinary = config["claude_binary"] as? String ?? "claude"
        claudeEnabled = config["claude_enabled"] as? Bool ?? true
        snippetsEnabled = config["snippets_enabled"] as? Bool ?? true
        hasLoaded = true
    }

    private func saveConfig() {
        guard hasLoaded else { return }
        let config: [String: Any] = [
            "clipboard_max_items": clipboardMaxItems,
            "clipboard_max_image_items": clipboardMaxImageItems,
            "search_dirs": ["~"],
            "debounce_delay": debounceDelay,
            "claude_binary": claudeBinary,
            "claude_enabled": claudeEnabled,
            "snippets_enabled": snippetsEnabled,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let _ = rc_config_save(jsonStr)
    }
}

// MARK: - Components

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
        }
    }
}

/// Card container with subtle background.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Warning/hint row with action button.
struct SettingsHint: View {
    let icon: String
    let color: Color
    let text: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Fix") { action() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
        }
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 14))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Rectangle())
    }
}

struct SidebarItemCustomIcon<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon().frame(width: 18)
            Text(title)
                .font(.system(size: 14))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Rectangle())
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
            Spacer()
            content()
        }
    }
}

/// Custom hotkey picker — badge button + popover dropdown.
struct HotkeyPicker: View {
    @Binding var selected: String
    let onChange: (String) -> Void
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 4) {
                ForEach(selected.split(separator: " ").map(String.init), id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(HotkeyConfig.options.map(\.displayName), id: \.self) { option in
                    Button(action: {
                        selected = option
                        onChange(option)
                        showPopover = false
                    }) {
                        HStack(spacing: 4) {
                            ForEach(option.split(separator: " ").map(String.init), id: \.self) { key in
                                Text(key)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(option == selected ? 0.15 : 0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Spacer()
                            if option == selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 210)
        }
    }
}

/// Ainto logo icon loaded from bundled PNG for the About section.
struct AintoAboutIcon: View {
    let size: CGFloat

    var body: some View {
        if let image = loadAboutIcon() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "command.square.fill")
                .font(.system(size: size * 0.75))
                .foregroundColor(.accentColor)
        }
    }

    private func loadAboutIcon() -> NSImage? {
        if let url = ResourceBundle.url(forResource: "ainto-about", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

struct AboutButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
