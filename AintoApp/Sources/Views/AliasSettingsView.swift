import AppKit
import SwiftUI
import AintoCore

struct AliasSettingsView: View {
    @State private var aliases: [LauncherAlias] = []
    @State private var targets: [AliasTargetOption] = []
    @State private var newAlias = ""
    @State private var selectedTarget: LauncherTargetRef?
    @State private var targetFilter = ""
    @State private var validationError: String?
    @State private var savedMessage: String?

    private var filteredTargets: [AliasTargetOption] {
        let filter = targetFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return targets }
        return targets.filter {
            $0.title.localizedCaseInsensitiveContains(filter)
                || $0.detail.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Aliases", icon: "arrow.triangle.branch")

            Text(
                "Aliases are exact, case-insensitive shortcuts. "
                    + "They promote the mapped result without hiding normal search matches."
            )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            SettingsCard {
                VStack(spacing: 12) {
                    TextField("New alias, for example tc", text: $newAlias)
                        .textFieldStyle(.roundedBorder)
                    TextField("Filter targets", text: $targetFilter)
                        .textFieldStyle(.roundedBorder)
                    Picker("Target", selection: $selectedTarget) {
                        Text("Choose a target").tag(Optional<LauncherTargetRef>.none)
                        ForEach(filteredTargets) { target in
                            Text("\(target.title) — \(target.detail)")
                                .tag(Optional(target.ref))
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Add Alias") { addAlias() }
                            .disabled(AliasStore.normalize(newAlias).isEmpty || selectedTarget == nil)
                    }
                }
            }

            if aliases.isEmpty {
                Text("No aliases configured.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                SettingsCard {
                    VStack(spacing: 12) {
                        ForEach(Array(aliases.indices), id: \.self) { index in
                            HStack(spacing: 10) {
                                TextField("Alias", text: $aliases[index].alias)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 110)
                                Picker("", selection: targetBinding(index)) {
                                    ForEach(targetsIncludingUnavailable(for: aliases[index])) { target in
                                        Text("\(target.title) — \(target.detail)").tag(target.ref)
                                    }
                                }
                                .labelsHidden()
                                Spacer()
                                Button {
                                    aliases.remove(at: index)
                                    persist()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                            if index < aliases.count - 1 { Divider().opacity(0.25) }
                        }
                        HStack {
                            Spacer()
                            Button("Save Changes") { persist() }
                        }
                    }
                }
            }

            if let validationError {
                Text(validationError).font(.system(size: 12)).foregroundStyle(.red)
            } else if let savedMessage {
                Text(savedMessage).font(.system(size: 12)).foregroundStyle(.green)
            }
        }
        .onAppear {
            aliases = AliasStore.load()
            targets = Self.loadTargets()
            selectedTarget = targets.first?.ref
        }
    }

    private func targetBinding(_ index: Int) -> Binding<LauncherTargetRef> {
        Binding(
            get: { aliases[index].target },
            set: {
                aliases[index].targetType = $0.kind
                aliases[index].targetID = $0.id
            }
        )
    }

    private func targetsIncludingUnavailable(for entry: LauncherAlias) -> [AliasTargetOption] {
        guard !targets.contains(where: { $0.ref == entry.target }) else { return targets }
        return targets + [AliasTargetOption(ref: entry.target, title: "Unavailable target", detail: entry.targetID)]
    }

    private func addAlias() {
        guard let selectedTarget else { return }
        let entry = LauncherAlias(
            alias: newAlias.trimmingCharacters(in: .whitespacesAndNewlines),
            targetType: selectedTarget.kind,
            targetID: selectedTarget.id
        )
        let candidate = aliases + [entry]
        if let error = AliasStore.validate(candidate) {
            validationError = error
            savedMessage = nil
            return
        }
        aliases = candidate
        newAlias = ""
        persist()
    }

    private func persist() {
        if let error = AliasStore.validate(aliases) {
            validationError = error
            savedMessage = nil
            return
        }
        guard AliasStore.save(aliases) else {
            validationError = "Aliases could not be saved."
            savedMessage = nil
            return
        }
        validationError = nil
        savedMessage = "Aliases saved."
    }

    private static func loadTargets() -> [AliasTargetOption] {
        var options: [AliasTargetOption] = [
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .launcherCommand, id: "file-search"),
                title: "File Search",
                detail: "Launcher Command"
            ),
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .launcherCommand, id: "clipboard-history"),
                title: "Clipboard History",
                detail: "Launcher Command"
            )
        ]

        options += SystemAction.allCases.map {
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .systemAction, id: $0.id),
                title: $0.title,
                detail: "System Action"
            )
        }
        options += AICommand.loadAll().map {
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .aiCommand, id: $0.id),
                title: $0.name,
                detail: "AI Command"
            )
        }
        options += loadSnippetTargets()
        options += loadAppTargets()
        return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func loadSnippetTargets() -> [AliasTargetOption] {
        guard let cString = rc_snippets_load() else { return [] }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AliasTargetOption(
                ref: LauncherTargetRef(kind: .snippet, id: id),
                title: entry["name"] as? String ?? "Untitled Snippet",
                detail: "Snippet"
            )
        }
    }

    private static func loadAppTargets() -> [AliasTargetOption] {
        guard let cString = rc_get_all_apps() else { return [] }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let path = entry["path"] as? String else { return nil }
            let bundleID = entry["bundle_id"] as? String
            return AliasTargetOption(
                ref: SearchViewModel.appTargetRef(bundleID: bundleID, path: path),
                title: entry["display_name"] as? String
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                detail: "Application"
            )
        }
    }
}
