import AppKit
import SwiftUI

struct FileSearchSettingsView: View {
    @Binding var paths: [String]
    @Binding var allLocations: Bool
    @Binding var includeHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "File Search", icon: "doc.text.magnifyingglass")

            VStack(alignment: .leading, spacing: 8) {
                Text("Search scope")
                    .font(.system(size: 14, weight: .medium))
                SettingsCard {
                    Picker("Search scope", selection: $allLocations) {
                        Text("Selected Folders").tag(false)
                        Text("Entire Mac").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            if allLocations {
                SettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Search the entire Mac using Spotlight")
                                .font(.system(size: 13, weight: .medium))
                            Text("Only indexed files are searched; Ainto never crawls the disk.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(savedFoldersMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            } else {
                selectedFoldersSection
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Search options")
                    .font(.system(size: 14, weight: .medium))
                SettingsCard {
                    SettingsRow(label: "Include hidden files") {
                        Toggle("", isOn: $includeHidden)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full Disk Access")
                            .font(.system(size: 13))
                        Text(
                            "Allows Spotlight to return more protected indexed locations. "
                                + "It does not change the search scope or scan unindexed files."
                        )
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Open System Settings") { openFullDiskAccessSettings() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var selectedFoldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search folders")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button("Add Folder…") { addFolder() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            SettingsCard {
                VStack(spacing: 10) {
                    if paths.isEmpty {
                        Text("No folders selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                paths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove folder")
                        }
                    }
                }
            }
            if paths.isEmpty {
                Text("Add at least one folder to enable File Search in this mode.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var savedFoldersMessage: String {
        guard !paths.isEmpty else {
            return "Switch to Selected Folders to choose a narrower search scope."
        }
        let noun = paths.count == 1 ? "folder is" : "folders are"
        return "Your \(paths.count) configured \(noun) preserved for Selected Folders mode."
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a File Search folder"
        // Start at the filesystem root so system folders such as /Library are
        // visible without requiring the user to know Finder's Go to Folder shortcut.
        panel.directoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if !paths.contains(path) { paths.append(path) }
        }
    }

    private func openFullDiskAccessSettings() {
        // Permission and search scope are independent. Opening System Settings
        // must not silently switch from Selected Folders to Entire Mac.
        let primary = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(primary),
           let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }
}
