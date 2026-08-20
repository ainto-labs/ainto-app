import AppKit
import SwiftUI

struct FileSearchSettingsView: View {
    @Binding var paths: [String]
    @Binding var allLocations: Bool
    @Binding var includeHidden: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "File Search", icon: "doc.text.magnifyingglass")

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRow(label: "Search entire Mac") {
                        Toggle("", isOn: $allLocations).labelsHidden().toggleStyle(.switch)
                    }
                    Text(
                        "Full Disk Access grants permission, while this toggle expands "
                            + "the Spotlight scope beyond the folders below."
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Divider().opacity(0.3)
                    SettingsRow(label: "Include hidden files") {
                        Toggle("", isOn: $includeHidden).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

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
                if paths.isEmpty && !allLocations {
                    Text("Add at least one folder or enable Search entire Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if allLocations {
                    Text("These folders will be used when Search entire Mac is turned off.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            SettingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full Disk Access")
                            .font(.system(size: 13))
                        Text(
                            "Allows Spotlight to return more protected indexed locations. "
                                + "It does not scan unindexed files."
                        )
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Open Settings") { openFullDiskAccessSettings() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
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
        // Permission alone does not change NSMetadataQuery's scope. Enable the
        // whole-Mac scope so returning from System Settings behaves as expected.
        allLocations = true
        let primary = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(primary),
           let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }
}
