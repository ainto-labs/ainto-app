import Foundation
import AintoCore

extension Notification.Name {
    static let aliasesDidChange = Notification.Name("app.ainto.aliasesDidChange")
}

enum LauncherTargetKind: String, Codable, CaseIterable {
    case app
    case aiCommand = "ai_command"
    case snippet
    case launcherCommand = "launcher_command"
    case systemAction = "system_action"
}

struct LauncherTargetRef: Hashable, Codable {
    let kind: LauncherTargetKind
    let id: String
}

struct LauncherAlias: Codable, Identifiable, Hashable {
    var alias: String
    var targetType: LauncherTargetKind
    var targetID: String

    var id: String { AliasStore.normalize(alias) }
    var target: LauncherTargetRef { LauncherTargetRef(kind: targetType, id: targetID) }

    enum CodingKeys: String, CodingKey {
        case alias
        case targetType = "target_type"
        case targetID = "target_id"
    }
}

struct AliasTargetOption: Identifiable, Hashable {
    let ref: LauncherTargetRef
    let title: String
    let detail: String
    var id: String { "\(ref.kind.rawValue):\(ref.id)" }
}

enum AliasStore {
    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCompatibilityMapping
    }

    static func load() -> [LauncherAlias] {
        guard let cString = rc_aliases_load() else { return [] }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LauncherAlias].self, from: data)) ?? []
    }

    static func validate(_ aliases: [LauncherAlias]) -> String? {
        var used = Set<String>()
        for entry in aliases {
            let normalized = normalize(entry.alias)
            if normalized.isEmpty { return "Alias cannot be empty." }
            if !used.insert(normalized).inserted {
                return "The alias ‘\(entry.alias.trimmingCharacters(in: .whitespacesAndNewlines))’ is already in use."
            }
        }
        return nil
    }

    @discardableResult
    static func save(_ aliases: [LauncherAlias]) -> Bool {
        guard validate(aliases) == nil,
              let data = try? JSONEncoder().encode(aliases),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        guard rc_aliases_save(json) == 0 else { return false }
        NotificationCenter.default.post(name: .aliasesDidChange, object: nil)
        return true
    }
}
