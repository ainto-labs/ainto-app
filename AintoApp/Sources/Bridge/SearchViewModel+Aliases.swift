import AppKit
import Foundation
import AintoCore

extension SearchViewModel {
    nonisolated static func appTargetRef(bundleID: String?, path: String) -> LauncherTargetRef {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let bundleID, !bundleID.isEmpty {
            // Bundle IDs are not unique when multiple copies of an app are installed.
            return LauncherTargetRef(kind: .app, id: "bundle:\(bundleID)|path:\(standardizedPath)")
        }
        return LauncherTargetRef(kind: .app, id: "path:\(standardizedPath)")
    }

    func resolvedAliasResult(for query: String) -> SearchResult? {
        let normalized = AliasStore.normalize(query)
        guard !normalized.isEmpty,
              let entry = aliases.first(where: { AliasStore.normalize($0.alias) == normalized }),
              var result = result(for: entry.target)
        else { return nil }
        result.subtitle = "Alias: \(entry.alias) • \(result.subtitle)"
        result.score = 10_000
        return result
    }

    private func result(for target: LauncherTargetRef) -> SearchResult? {
        switch target.kind {
        case .app:
            return appResult(targetID: target.id)
        case .aiCommand:
            guard aiEnabled,
                  let command = AICommand.loadAll().first(where: { $0.id == target.id })
            else { return nil }
            var result = SearchResult(
                title: command.name,
                subtitle: "AI Command",
                icon: nil,
                systemIcon: command.icon,
                targetRef: target
            ) { [weak self] in
                self?.incrementCommandRanking(command)
                self?.executeAICommand(command)
            }
            result.actions = aiCommandActions(for: command)
            return result
        case .snippet:
            return snippetResult(targetID: target.id)
        case .launcherCommand:
            switch target.id {
            case "file-search":
                return fileSearchCommandResult(score: 0)
            case "clipboard-history":
                return SearchResult(
                    title: "Clipboard History",
                    subtitle: "Command",
                    icon: nil,
                    systemIcon: "doc.on.clipboard",
                    targetRef: target
                ) { [weak self] in self?.goToClipboard() }
            default:
                return nil
            }
        case .systemAction:
            guard let action = SystemAction(rawValue: target.id) else { return nil }
            return systemActionResult(action, score: 0)
        }
    }

    private func appResult(targetID: String) -> SearchResult? {
        guard let cString = rc_get_all_apps() else { return nil }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = entries.first(where: { entry in
                  let path = entry["path"] as? String ?? ""
                  let bundleID = entry["bundle_id"] as? String
                  return Self.appTargetRef(bundleID: bundleID, path: path).id == targetID
              })
        else { return nil }

        let name = entry["display_name"] as? String ?? ""
        let path = entry["path"] as? String ?? ""
        var result = SearchResult(
            title: name,
            subtitle: "Application",
            icon: loadAppIcon(path: path),
            systemIcon: "app.fill",
            targetRef: LauncherTargetRef(kind: .app, id: targetID)
        ) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            rc_update_ranking(path)
        }
        result.actions = Self.appActions(path: path)
        return result
    }

    private func snippetResult(targetID: String) -> SearchResult? {
        guard let cString = rc_snippets_load() else { return nil }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let snippet = entries.first(where: { $0["id"] as? String == targetID })
        else { return nil }
        let name = snippet["name"] as? String ?? ""
        let keyword = snippet["keyword"] as? String ?? ""
        let expansion = snippet["expansion"] as? String ?? ""
        return SearchResult(
            title: name,
            subtitle: "Snippet: \(keyword)",
            icon: nil,
            systemIcon: "doc.text.fill",
            targetRef: LauncherTargetRef(kind: .snippet, id: targetID)
        ) { [weak self] in
            self?.expandAndPasteSnippet(expansion)
        }
    }
}
