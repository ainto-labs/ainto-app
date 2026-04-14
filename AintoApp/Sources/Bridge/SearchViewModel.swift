import AppKit
import Foundation
import AintoCore

/// AI command — loaded from ~/.config/ainto/ai-commands.toml
struct AICommand: Identifiable {
    var id: String
    var name: String
    var icon: String
    var prompt: String  // {selection} will be replaced with selected text

    static func new() -> AICommand {
        AICommand(id: UUID().uuidString, name: "", icon: "sparkle", prompt: "{selection}")
    }

    /// Load all commands from TOML (includes defaults on first run).
    static func loadAll() -> [AICommand] {
        guard let cStr = rc_ai_commands_load() else { return [] }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return entries.map { entry in
            AICommand(
                id: entry["name"] as? String ?? UUID().uuidString,
                name: entry["name"] as? String ?? "",
                icon: entry["icon"] as? String ?? "sparkle",
                prompt: entry["prompt"] as? String ?? ""
            )
        }
    }
}

/// Fuzzy match score. Returns 0 if no match.
/// Higher = better match. Mirrors Rust's fuzzy_score logic.
func fuzzyScore(_ query: String, _ target: String) -> Int {
    let q = query.lowercased()
    let t = target.lowercased()
    if t == q { return 200 }
    if t.hasPrefix(q) { return 150 }
    // Word-boundary initials: "iw" → "Improve Writing" (I + W)
    if wordBoundaryMatch(q, target) { return 120 }
    if t.contains(q) { return 100 }
    if fuzzyMatch(q, t) { return 60 + Int(Double(q.count) / Double(t.count) * 40) }
    return 0
}

/// Check if query matches the first letter of each word or camelCase boundary.
/// "iw" matches "Improve Writing", "vsc" matches "Visual Studio Code"
func wordBoundaryMatch(_ query: String, _ target: String) -> Bool {
    let initials = extractWordBoundaries(target)
    let qChars = Array(query.lowercased())
    let iChars = initials.map { Character($0.lowercased()) }
    guard !qChars.isEmpty, !iChars.isEmpty else { return false }
    var qi = 0
    for ic in iChars {
        if qi < qChars.count && ic == qChars[qi] {
            qi += 1
        }
    }
    return qi == qChars.count
}

/// Extract first char + chars after space/hyphen + uppercase in camelCase.
func extractWordBoundaries(_ name: String) -> [Character] {
    var boundaries: [Character] = []
    let chars = Array(name)
    for (i, c) in chars.enumerated() {
        if i == 0 && c.isLetter {
            boundaries.append(c)
        } else if c.isUppercase && i > 0 && chars[i-1].isLowercase {
            boundaries.append(c)
        } else if i > 0 && (chars[i-1] == " " || chars[i-1] == "-" || chars[i-1] == "_") && c.isLetter {
            boundaries.append(c)
        }
    }
    return boundaries
}

/// Simple fuzzy match: query chars appear in order in target.
/// Returns true if all characters of query appear in target in order.
func fuzzyMatch(_ query: String, _ target: String) -> Bool {
    if query.isEmpty { return true }
    let q = query.lowercased()
    let t = target.lowercased()
    var qi = q.startIndex
    for tc in t {
        if tc == q[qi] {
            qi = q.index(after: qi)
            if qi == q.endIndex { return true }
        }
    }
    return false
}

/// Sendable wrapper for UnsafeMutableRawPointer (for passing to Task.detached).
struct SendablePointer: @unchecked Sendable {
    let ptr: UnsafeMutableRawPointer
}

/// A message in the Claude conversation.
struct ClaudeMessage: Identifiable {
    let id = UUID()
    let role: ClaudeRole
    var text: String
}

enum ClaudeRole {
    case user
    case assistant
}

/// Active page in the launcher.
enum LauncherPage: Equatable {
    case main
    case clipboard
    case snippets
    case aiCommands
    case claude
}

enum SearchMode: Equatable {
    case apps    // default: search apps/commands
    case claude  // Tab: ask Claude
}

/// An action available for a search result.
struct ActionItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String // SF Symbol name
    let shortcut: String? // e.g. "⌘ O" for display
    var keepPanel: Bool = false // true = don't hide panel after action (for navigation)
    let action: () -> Void
}

/// Search result model for the UI.
struct SearchResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: NSImage?
    let systemIcon: String? // fallback SF Symbol name
    var score: Int = 0 // higher = better match, used for unified sorting
    let action: () -> Void
    var actions: [ActionItem] = [] // Cmd+K to show

    /// Resolved icon: app icon or SF Symbol fallback
    var displayIcon: NSImage {
        if let icon { return icon }
        if let name = systemIcon,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return img
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage()
    }
}

/// Clipboard entry decoded from Rust JSON.
struct ClipboardItem: Identifiable {
    let id: Int64
    let contentType: String // "text" | "image" | "file"
    let text: String?
    let filePath: String?
    let imageFilename: String?
    let hash: UInt64
    let sourceApp: String?
    let lastCopiedAt: Int64
    let copyCount: UInt32

    var displayTitle: String {
        switch contentType {
        case "image": return "Image"
        case "file":
            if let path = filePath {
                return (path as NSString).lastPathComponent
            }
            return "File"
        default:
            return text?.components(separatedBy: .newlines).first ?? ""
        }
    }

    var iconName: String {
        switch contentType {
        case "image": return "photo"
        case "file": return "doc.fill"
        default: return "doc.text"
        }
    }

    var contentTypeLabel: String {
        switch contentType {
        case "image": return "Image"
        case "file": return "File"
        default: return "Text"
        }
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(lastCopiedAt))
    }

    var relativeTime: String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    /// Time group for section headers.
    var timeGroup: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return "Earlier"
    }

    /// Full image path on disk.
    var imagePath: String? {
        guard let filename = imageFilename else { return nil }
        guard !filename.contains("/"), !filename.contains("..") else { return nil }
        guard let cStr = rc_clipboard_image_dir() else { return nil }
        let dir = String(cString: cStr)
        rc_free_string(cStr)
        return (dir as NSString).appendingPathComponent(filename)
    }

    /// Load NSImage for display (file icon or image thumbnail).
    var displayImage: NSImage? {
        switch contentType {
        case "file":
            if let path = filePath {
                return NSWorkspace.shared.icon(forFile: path)
            }
            return nil
        case "image":
            if let path = imagePath {
                return NSImage(contentsOfFile: path)
            }
            return nil
        default:
            return nil
        }
    }
}

/// Snippet item model.
struct SnippetItem: Identifiable {
    var id: String
    var name: String
    var keyword: String
    var expansion: String

    static func new() -> SnippetItem {
        SnippetItem(id: UUID().uuidString, name: "", keyword: "", expansion: "")
    }
}

/// ViewModel managing search state and Rust FFI calls.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published var shouldSelectAll = false
    @Published var page: LauncherPage = .main
    @Published var searchMode: SearchMode = .apps

    // Claude state
    @Published var claudeMessages: [ClaudeMessage] = []
    @Published var claudeIsStreaming = false
    private var claudeSession: UnsafeMutableRawPointer?
    private var claudeSessionId: String?

    // Snippet state
    @Published var snippets: [SnippetItem] = []
    @Published var snippetSelectedIndex: Int = 0
    @Published var snippetFilter: String = ""
    @Published var isEditingSnippet = false
    @Published var editingSnippet: SnippetItem?

    // AI Commands state
    @Published var aiCommands: [AICommand] = []
    @Published var aiCommandSelectedIndex: Int = 0
    @Published var aiCommandFilter: String = ""
    @Published var isEditingAICommand = false
    @Published var editingAICommand: AICommand?

    // Clipboard state
    @Published var clipboardItems: [ClipboardItem] = []
    /// Not @Published — selection changes are handled directly by NSTableView
    /// to avoid triggering SwiftUI re-renders on every arrow key press.
    var clipboardSelectedIndex: Int = 0
    private let clipboardPageSize = 50
    private(set) var clipboardHasMore = true
    var clipboardFilter: String = "" {
        didSet {
            if clipboardFilter.isEmpty {
                clipboardFilterTask?.cancel()
                if !debouncedClipboardFilter.isEmpty {
                    debouncedClipboardFilter = ""
                    // Reload unfiltered from SQLite
                    loadClipboardItems()
                }
            } else {
                scheduleClipboardFilter()
            }
        }
    }
    @Published var clipboardTypeFilter: ClipboardTypeFilter = .all {
        didSet { rebuildFilteredClipboardItems() }
    }
    @Published var debouncedClipboardFilter: String = ""
    private var clipboardFilterTask: DispatchWorkItem?

    // Action panel
    @Published var showActionPanel = false

    /// Icon cache keyed by app path
    private var iconCache: [String: NSImage] = [:]


    /// Callback to hide panel and paste to frontmost app (set by SearchPanel)
    var onPasteAndHide: (() -> Void)?

    /// Callback to move clipboard table selection (set by ClipboardTableView).
    /// Bypasses @Published to avoid SwiftUI re-render on every arrow key.
    var onClipboardSelectionMove: ((_ newIndex: Int) -> Void)?

    /// Callback to reload text expander snippets (set by AppDelegate)
    var onSnippetsChanged: (() -> Void)?

    var statusText: String {
        switch results.count {
        case 0: return "No results"
        case 1: return "1 result"
        default: return "\(results.count) results"
        }
    }

    func clearQuery() {
        query = ""
        results = []
        selectedIndex = 0
    }

    func selectAll() {
        shouldSelectAll = true
        // Refresh default results if query is empty
        if query.isEmpty {
            results = buildDefaultResults()
        }
    }

    // MARK: - Navigation

    func goToSnippets() {
        page = .snippets
        snippetFilter = ""
        snippetSelectedIndex = 0
        isEditingSnippet = false
        editingSnippet = nil
        loadSnippets()
        focusFilterField()
    }

    func goToAICommands() {
        page = .aiCommands
        aiCommandFilter = ""
        aiCommandSelectedIndex = 0
        isEditingAICommand = false
        editingAICommand = nil
        loadAICommands()
        focusFilterField()
    }

    func goToClipboard() {
        page = .clipboard
        clipboardFilter = ""
        debouncedClipboardFilter = ""
        clipboardSelectedIndex = 0
        loadClipboardItems()
        focusFilterField()
    }

    func goBack() {
        if page == .claude {
            claudeCancel()
            claudeMessages.removeAll()
            claudeSessionId = nil // start fresh next time
        }
        if page == .aiCommands && isEditingAICommand {
            cancelEditingAICommand()
            return
        }
        clipboardFilter = "" // didSet handles cancel + debouncedClipboardFilter
        page = .main
        searchMode = .apps
        // TextField is always in the view hierarchy (ZStack), so focus immediately.
        // selectAll is chained after focus succeeds to avoid race conditions.
        focusFilterField(then: { [weak self] in self?.selectAll() })
    }

    // MARK: - Main search

    func performSearch(query: String) {
        guard !query.isEmpty else {
            results = buildDefaultResults()
            selectedIndex = 0
            return
        }

        // Check for /cc prefix (Claude Code)
        if query.hasPrefix("/cc ") {
            let prompt = String(query.dropFirst(4))
            results = [
                SearchResult(
                    title: "Ask Claude: \(prompt)",
                    subtitle: "Claude Code",
                    icon: nil,
                    systemIcon: "bubble.left.fill"
                ) { [weak self] in
                    self?.startClaude(prompt: prompt)
                }
            ]
            selectedIndex = 0
            return
        }

        // Search apps via Rust FFI
        var appResults: [SearchResult] = []

        if let cStr = rc_search_apps(query) {
            let jsonStr = String(cString: cStr)
            rc_free_string(cStr)

            if let data = jsonStr.data(using: .utf8),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                appResults = entries.prefix(8).map { entry in
                    let name = entry["display_name"] as? String ?? ""
                    let path = entry["path"] as? String ?? ""
                    let ranking = entry["ranking"] as? Int ?? 0
                    let icon = self.loadAppIcon(path: path)
                    var result = SearchResult(
                        title: name,
                        subtitle: "Application",
                        icon: icon,
                        systemIcon: "app.fill",
                        score: fuzzyScore(query, name) + ranking
                    ) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        rc_update_ranking(path)
                    }
                    result.actions = Self.appActions(path: path)
                    return result
                }
            }
        }

        // Search snippets
        var snippetResults: [SearchResult] = []
        if let cStr = rc_snippets_load() {
            let jsonStr = String(cString: cStr)
            rc_free_string(cStr)

            if let data = jsonStr.data(using: .utf8),
               let snippets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                snippetResults = snippets
                    .filter { snippet in
                        let name = snippet["name"] as? String ?? ""
                        let keyword = snippet["keyword"] as? String ?? ""
                        return fuzzyMatch(query, name) || fuzzyMatch(query, keyword)
                    }
                    .prefix(5)
                    .map { snippet in
                        let name = snippet["name"] as? String ?? ""
                        let keyword = snippet["keyword"] as? String ?? ""
                        let expansion = snippet["expansion"] as? String ?? ""
                        return SearchResult(
                            title: name,
                            subtitle: "Snippet: \(keyword)",
                            icon: nil,
                            systemIcon: "doc.text.fill"
                        ) {
                            if let cStr = rc_snippet_expand(expansion, nil) {
                                let expanded = String(cString: cStr)
                                rc_free_string(cStr)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(expanded, forType: .string)
                            }
                        }
                    }
            }
        }

        // Built-in commands that fuzzy match
        var commandResults: [SearchResult] = []
        let q = query.lowercased()

        // AI commands (built-in + custom) — fuzzy match
        let matchingAICommands = AICommand.loadAll().filter { cmd in
            fuzzyMatch(q, cmd.name)
        }
        let rankedAICommands = matchingAICommands.sorted { a, b in
            self.commandRanking(for: a.name) > self.commandRanking(for: b.name)
        }
        for cmd in rankedAICommands.prefix(6) {
            let command = cmd
            let cmdScore = fuzzyScore(q, command.name) + self.commandRanking(for: command.name)
            var result = SearchResult(
                title: command.name,
                subtitle: "AI Command",
                icon: nil,
                systemIcon: command.icon,
                score: cmdScore
            ) { [weak self] in
                self?.incrementCommandRanking(command.name)
                self?.executeAICommand(command)
            }
            result.actions = aiCommandActions(for: command)
            commandResults.append(result)
        }

        if fuzzyMatch(q, "ai commands") || fuzzyMatch(q, "manage ai commands") {
            commandResults.append(SearchResult(
                title: "AI Commands",
                subtitle: "Manage AI Commands",
                icon: nil,
                systemIcon: "sparkle",
                score: fuzzyScore(q, "AI Commands")
            ) { [weak self] in
                self?.goToAICommands()
            })
        }

        if fuzzyMatch(q, "snippets") {
            let r = SearchResult(
                title: "Snippets",
                subtitle: "Command",
                icon: nil,
                systemIcon: "text.quote",
                score: fuzzyScore(query, "Snippets") + commandRanking(for: "Snippets")
            ) { [weak self] in
                self?.incrementCommandRanking("Snippets")
                self?.goToSnippets()
            }
            commandResults.append(r)
        }

        if fuzzyMatch(q, "clipboard history") {
            let r = SearchResult(
                title: "Clipboard History",
                subtitle: "Command",
                icon: nil,
                systemIcon: "doc.on.clipboard",
                score: fuzzyScore(query, "Clipboard History") + commandRanking(for: "Clipboard History")
            ) { [weak self] in
                self?.incrementCommandRanking("Clipboard History")
                self?.goToClipboard()
            }
            commandResults.append(r)
        }

        var allResults = appResults + commandResults + snippetResults
        allResults.sort { $0.score > $1.score }
        results = Array(allResults.prefix(20))
        selectedIndex = 0
    }

    func moveSelection(by offset: Int) {
        switch page {
        case .clipboard:
            let count = filteredClipboardItems.count
            guard count > 0 else { return }
            clipboardSelectedIndex = max(0, min(clipboardSelectedIndex + offset, count - 1))
            onClipboardSelectionMove?(clipboardSelectedIndex)
        case .snippets:
            let count = filteredSnippets.count
            guard count > 0 else { return }
            snippetSelectedIndex = max(0, min(snippetSelectedIndex + offset, count - 1))
        case .aiCommands:
            let count = filteredAICommands.count
            guard count > 0 else { return }
            aiCommandSelectedIndex = max(0, min(aiCommandSelectedIndex + offset, count - 1))
        case .main:
            guard !results.isEmpty else { return }
            selectedIndex = max(0, min(selectedIndex + offset, results.count - 1))
        case .claude:
            break // no list navigation in Claude view
        }
    }

    func openSelected() {
        switch page {
        case .clipboard:
            pasteSelectedClipboardItem()
        case .snippets:
            expandSelectedSnippet()
        case .aiCommands:
            executeSelectedAICommand()
        case .main:
            guard selectedIndex < results.count else { return }
            results[selectedIndex].action()
        case .claude:
            break
        }
    }

    // MARK: - Clipboard

    /// Reload clipboard items only if the clipboard page is currently visible.
    func reloadClipboardIfVisible() {
        guard page == .clipboard else { return }
        loadClipboardItems()
    }

    private func scheduleClipboardFilter() {
        clipboardFilterTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debouncedClipboardFilter = self.clipboardFilter
            // Search via SQLite instead of in-memory filter
            self.clipboardItems = self.fetchClipboardItems(query: self.debouncedClipboardFilter, offset: 0)
            self.clipboardHasMore = self.clipboardItems.count >= self.clipboardPageSize
            self.clipboardSelectedIndex = 0
            self.rebuildFilteredClipboardItems()
        }
        clipboardFilterTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }

    func loadClipboardItems() {
        clipboardItems = fetchClipboardItems(query: nil, offset: 0)
        clipboardHasMore = clipboardItems.count >= clipboardPageSize
        clipboardSelectedIndex = 0
        rebuildFilteredClipboardItems()
    }

    /// Load next page and append to existing items.
    func loadMoreClipboardItems() {
        guard clipboardHasMore else { return }
        let query = debouncedClipboardFilter.isEmpty ? nil : debouncedClipboardFilter
        let newItems = fetchClipboardItems(query: query, offset: clipboardItems.count)
        clipboardHasMore = newItems.count >= clipboardPageSize
        clipboardItems.append(contentsOf: newItems)
        rebuildFilteredClipboardItems()
    }

    /// Fetch clipboard items from Rust/SQLite with optional search query.
    private func fetchClipboardItems(query: String?, offset: Int) -> [ClipboardItem] {
        let cStr: UnsafePointer<CChar>?
        if let query, !query.isEmpty {
            cStr = rc_clipboard_search_paged(query, UInt64(clipboardPageSize), UInt64(offset))
        } else {
            cStr = rc_clipboard_get_recent_paged(UInt64(clipboardPageSize), UInt64(offset))
        }
        guard let cStr else { return [] }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return entries.map { entry in
            ClipboardItem(
                id: entry["id"] as? Int64 ?? 0,
                contentType: entry["content_type"] as? String ?? "text",
                text: entry["text"] as? String,
                filePath: entry["file_path"] as? String,
                imageFilename: entry["image_filename"] as? String,
                hash: (entry["hash"] as? NSNumber)?.uint64Value ?? 0,
                sourceApp: entry["source_app"] as? String,
                lastCopiedAt: entry["last_copied_at"] as? Int64 ?? 0,
                copyCount: (entry["copy_count"] as? NSNumber)?.uint32Value ?? 0
            )
        }
    }

    /// Cached filtered result + derived data — recalculated only when filter
    /// inputs change, not on every SwiftUI body evaluation.
    @Published private(set) var filteredClipboardItems: [ClipboardItem] = []
    private(set) var clipboardGroupedItems: [String: [ClipboardItem]] = [:]
    private(set) var clipboardGroupedKeys: [String] = []
    private(set) var clipboardIndexMap: [Int64: Int] = [:]

    private func rebuildFilteredClipboardItems() {
        var items = clipboardItems

        // Apply type filter (in-memory, since SQLite doesn't know our type categories)
        switch clipboardTypeFilter {
        case .all: break
        case .text: items = items.filter { $0.contentType == "text" }
        case .images: items = items.filter { $0.contentType == "image" }
        case .files: items = items.filter { $0.contentType == "file" }
        }

        filteredClipboardItems = items

        // Rebuild derived data (used by ClipboardView)
        let grouped = Dictionary(grouping: items) { $0.timeGroup }
        clipboardGroupedItems = grouped
        let order = ["Today": 0, "Yesterday": 1, "Earlier": 2]
        clipboardGroupedKeys = grouped.keys.sorted { (order[$0] ?? 3) < (order[$1] ?? 3) }
        clipboardIndexMap = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }

    func pasteSelectedClipboardItem() {
        let items = filteredClipboardItems
        guard clipboardSelectedIndex < items.count else { return }
        let item = items[clipboardSelectedIndex]

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.contentType {
        case "text":
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case "file":
            if let path = item.filePath {
                let url = URL(fileURLWithPath: path) as NSURL
                pasteboard.writeObjects([url])
            }
        case "image":
            if let path = item.imagePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                pasteboard.setData(data, forType: .png)
            }
        default:
            break
        }

        // Hide panel and paste into the previously focused app
        onPasteAndHide?()
    }

    func deleteClipboardItem(id: Int64) {
        let _ = rc_clipboard_delete(id)
        loadClipboardItems()
    }

    // MARK: - Snippets

    func loadSnippets() {
        guard let cStr = rc_snippets_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        snippets = entries.map { entry in
            SnippetItem(
                id: entry["id"] as? String ?? UUID().uuidString,
                name: entry["name"] as? String ?? "",
                keyword: entry["keyword"] as? String ?? "",
                expansion: entry["expansion"] as? String ?? ""
            )
        }
        snippetSelectedIndex = 0
    }

    func saveSnippets() {
        let jsonArray: [[String: Any]] = snippets.map { s in
            ["id": s.id, "name": s.name, "keyword": s.keyword, "expansion": s.expansion]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let _ = rc_snippets_save(jsonStr)
        onSnippetsChanged?()
    }

    var filteredSnippets: [SnippetItem] {
        if snippetFilter.isEmpty { return snippets }
        let q = snippetFilter.lowercased()
        return snippets.filter {
            $0.name.lowercased().contains(q) || $0.keyword.lowercased().contains(q)
        }
    }

    func addSnippet() {
        editingSnippet = .new()
        isEditingSnippet = true
    }

    func editSelectedSnippet() {
        let items = filteredSnippets
        guard snippetSelectedIndex < items.count else { return }
        editingSnippet = items[snippetSelectedIndex]
        isEditingSnippet = true
    }

    func saveEditingSnippet() {
        guard let editing = editingSnippet else { return }
        if let idx = snippets.firstIndex(where: { $0.id == editing.id }) {
            snippets[idx] = editing
        } else {
            snippets.append(editing)
        }
        saveSnippets()
        isEditingSnippet = false
        editingSnippet = nil
        focusFilterField()
    }

    func cancelEditingSnippet() {
        isEditingSnippet = false
        editingSnippet = nil
        focusFilterField()
    }

    func deleteSnippet(id: String) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
        if snippetSelectedIndex >= filteredSnippets.count {
            snippetSelectedIndex = max(0, filteredSnippets.count - 1)
        }
    }

    func expandSelectedSnippet() {
        let items = filteredSnippets
        guard snippetSelectedIndex < items.count else { return }
        let snippet = items[snippetSelectedIndex]

        if let cStr = rc_snippet_expand(snippet.expansion, nil) {
            let expanded = String(cString: cStr)
            rc_free_string(cStr)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(expanded, forType: .string)
            onPasteAndHide?()
        }
    }

    // MARK: - AI Commands

    func loadAICommands() {
        aiCommands = AICommand.loadAll()
        aiCommandSelectedIndex = 0
    }

    func saveAICommands() {
        let jsonArray: [[String: Any]] = aiCommands.map { cmd in
            ["name": cmd.name, "icon": cmd.icon, "prompt": cmd.prompt]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let _ = rc_ai_commands_save(jsonStr)
    }

    var filteredAICommands: [AICommand] {
        if aiCommandFilter.isEmpty { return aiCommands }
        let q = aiCommandFilter.lowercased()
        return aiCommands.filter { $0.name.lowercased().contains(q) }
    }

    func addAICommand() {
        editingAICommand = .new()
        isEditingAICommand = true
    }

    func editSelectedAICommand() {
        let items = filteredAICommands
        guard aiCommandSelectedIndex < items.count else { return }
        editingAICommand = items[aiCommandSelectedIndex]
        isEditingAICommand = true
    }

    func saveEditingAICommand() {
        guard let editing = editingAICommand else { return }
        if let idx = aiCommands.firstIndex(where: { $0.id == editing.id }) {
            aiCommands[idx] = editing
        } else {
            aiCommands.append(editing)
        }
        // Update id to match name (used as stable identifier)
        if let idx = aiCommands.firstIndex(where: { $0.id == editing.id }) {
            aiCommands[idx].id = editing.name
        }
        saveAICommands()
        isEditingAICommand = false
        editingAICommand = nil
        focusFilterField()
    }

    func cancelEditingAICommand() {
        isEditingAICommand = false
        editingAICommand = nil
        focusFilterField()
    }

    func deleteAICommand(id: String) {
        aiCommands.removeAll { $0.id == id }
        saveAICommands()
        if aiCommandSelectedIndex >= filteredAICommands.count {
            aiCommandSelectedIndex = max(0, filteredAICommands.count - 1)
        }
    }

    private func aiCommandActions(for command: AICommand) -> [ActionItem] {
        [
            ActionItem(title: "Edit", icon: "pencil", shortcut: nil, keepPanel: true) { [weak self] in
                self?.goToAICommands()
                if let idx = self?.aiCommands.firstIndex(where: { $0.id == command.id }) {
                    self?.aiCommandSelectedIndex = idx
                    self?.editSelectedAICommand()
                }
            },
            ActionItem(title: "Manage AI Commands", icon: "sparkle", shortcut: nil, keepPanel: true) { [weak self] in
                self?.goToAICommands()
            },
        ]
    }

    func executeSelectedAICommand() {
        let items = filteredAICommands
        guard aiCommandSelectedIndex < items.count else { return }
        let command = items[aiCommandSelectedIndex]
        executeAICommand(command)
    }

    // MARK: - Action Panel

    /// Get actions for the currently selected result.
    var currentActions: [ActionItem] {
        switch page {
        case .main:
            guard selectedIndex < results.count else { return [] }
            return results[selectedIndex].actions
        default:
            return []
        }
    }

    func toggleActionPanel() {
        showActionPanel = !currentActions.isEmpty && !showActionPanel
    }

    /// App-specific actions.
    static func appActions(path: String) -> [ActionItem] {
        [
            ActionItem(title: "Open Application", icon: "arrow.up.forward.app", shortcut: "↵") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            },
            ActionItem(title: "Show in Finder", icon: "folder", shortcut: nil) {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            },
            ActionItem(title: "Show Info in Finder", icon: "info.circle", shortcut: nil) {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                // Cmd+I after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let source = CGEventSource(stateID: .combinedSessionState)
                    let iDown = CGEvent(keyboardEventSource: source, virtualKey: 0x22, keyDown: true)
                    iDown?.flags = .maskCommand
                    iDown?.post(tap: .cghidEventTap)
                    let iUp = CGEvent(keyboardEventSource: source, virtualKey: 0x22, keyDown: false)
                    iUp?.flags = .maskCommand
                    iUp?.post(tap: .cghidEventTap)
                }
            },
            ActionItem(title: "Copy Path", icon: "doc.on.doc", shortcut: nil) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            ActionItem(title: "Copy Bundle ID", icon: "number", shortcut: nil) {
                if let bundle = Bundle(path: path), let id = bundle.bundleIdentifier {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                }
            },
        ]
    }

    // MARK: - Default Results

    /// Build results shown when search query is empty.
    private func buildDefaultResults() -> [SearchResult] {
        var results: [SearchResult] = []

        // Frequently used apps (top 5 by ranking)
        if let cStr = rc_get_top_apps(5) {
            let jsonStr = String(cString: cStr)
            rc_free_string(cStr)
            if let data = jsonStr.data(using: .utf8),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for entry in entries {
                    let name = entry["display_name"] as? String ?? ""
                    let path = entry["path"] as? String ?? ""
                    let icon = self.loadAppIcon(path: path)
                    var result = SearchResult(
                        title: name,
                        subtitle: "Application",
                        icon: icon,
                        systemIcon: "app.fill"
                    ) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        rc_update_ranking(path)
                    }
                    result.actions = Self.appActions(path: path)
                    results.append(result)
                }
            }
        }

        // Built-in commands
        results.append(SearchResult(
            title: "Clipboard History",
            subtitle: "Command",
            icon: nil,
            systemIcon: "doc.on.clipboard"
        ) { [weak self] in self?.goToClipboard() })

        results.append(SearchResult(
            title: "Snippets",
            subtitle: "Command",
            icon: nil,
            systemIcon: "text.quote"
        ) { [weak self] in self?.goToSnippets() })

        results.append(SearchResult(
            title: "AI Commands",
            subtitle: "Command",
            icon: nil,
            systemIcon: "sparkle"
        ) { [weak self] in self?.goToAICommands() })

        // AI Commands — sorted by usage, top 4
        let aiCommands = AICommand.loadAll()
        let sorted = aiCommands.sorted { a, b in
            commandRanking(for: a.name) > commandRanking(for: b.name)
        }
        for cmd in sorted.prefix(4) {
            let command = cmd
            var result = SearchResult(
                title: command.name,
                subtitle: "AI Command",
                icon: nil,
                systemIcon: command.icon
            ) { [weak self] in
                self?.incrementCommandRanking(command.name)
                self?.executeAICommand(command)
            }
            result.actions = aiCommandActions(for: command)
            results.append(result)
        }

        return results
    }

    // MARK: - AI Commands

    /// Callback to grab selection from previous app (set by SearchPanel)
    var onGrabSelection: ((@escaping (String) -> Void) -> Void)?

    func executeAICommand(_ command: AICommand) {
        // Ask the panel to hide, grab selection from previous app, then proceed
        onGrabSelection? { [weak self] selectedText in
            guard let self else { return }

            guard !selectedText.isEmpty else {
                self.searchMode = .claude
                self.claudeMessages.append(ClaudeMessage(role: .assistant, text: "Please select some text in another app first, then try this command again."))
                self.page = .claude
                return
            }

            let prompt = command.prompt.replacingOccurrences(of: "{selection}", with: selectedText)
            self.searchMode = .claude
            self.query = prompt
            self.claudeAsk()
        }
    }

    // MARK: - Claude

    func toggleSearchMode() {
        if searchMode == .apps {
            searchMode = .claude
            results = []
        } else {
            searchMode = .apps
            claudeCancel()
            performSearch(query: query)
        }
    }

    func claudeAsk() {
        guard !query.isEmpty else { return }
        let prompt = query

        // Add user message
        claudeMessages.append(ClaudeMessage(role: .user, text: prompt))

        // Add empty assistant message (will be filled by streaming)
        claudeMessages.append(ClaudeMessage(role: .assistant, text: ""))

        // Switch to Claude page
        page = .claude
        claudeIsStreaming = true
        query = ""

        // Start session via Rust FFI
        // Only resume if we're on the Claude page already (continuing a conversation)
        let resumeId = (page == .claude) ? claudeSessionId : nil
        guard let session = rc_claude_start(prompt, "claude", resumeId) else {
            // Update last message with error
            if let lastIdx = claudeMessages.indices.last {
                claudeMessages[lastIdx].text = "Error: Could not start Claude. Is `claude` CLI installed?"
            }
            claudeIsStreaming = false
            return
        }
        claudeSession = session

        // Stream chunks in background (blocking reads on detached thread)
        let sendablePtr = SendablePointer(ptr: session)
        Task.detached {
            let ptr = sendablePtr.ptr
            var gotAnyText = false
            while true {
                guard let cStr = rc_claude_next_chunk(ptr) else {
                    // Stream done — capture session_id for resume
                    if let sidStr = rc_claude_get_session_id(ptr) {
                        let sid = String(cString: sidStr)
                        rc_free_string(sidStr)
                        await MainActor.run { [weak self] in
                            self?.claudeSessionId = sid
                        }
                    }

                    // If no text was received, show error
                    if !gotAnyText {
                        var errorMsg = "Claude process ended without output."
                        if let errStr = rc_claude_get_stderr(ptr) {
                            let stderr = String(cString: errStr)
                            rc_free_string(errStr)
                            if !stderr.isEmpty {
                                errorMsg = stderr
                            }
                        }
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            if let lastIdx = self.claudeMessages.indices.last {
                                self.claudeMessages[lastIdx].text = errorMsg
                            }
                            self.claudeSessionId = nil
                        }
                    }
                    await MainActor.run { [weak self] in
                        self?.claudeIsStreaming = false
                        self?.claudeSession = nil
                    }
                    rc_claude_free(ptr)
                    break
                }

                let chunk = String(cString: cStr)
                rc_free_string(cStr)
                gotAnyText = true

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let lastIdx = self.claudeMessages.indices.last {
                        self.claudeMessages[lastIdx].text += chunk
                    }
                }
            }
        }
    }

    func claudeCancel() {
        if let session = claudeSession {
            rc_claude_cancel(session)
            // Don't free here — background reader thread still holds the pointer.
            // It will be freed when rc_claude_next_chunk returns nil.
            claudeSession = nil
        }
        claudeIsStreaming = false
    }

    /// Replace the selected text in the previous app with the last Claude response.
    func replaceSelectedText() {
        guard let lastResponse = claudeMessages.last(where: { $0.role == .assistant }),
              !lastResponse.text.isEmpty else { return }

        // Write response to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResponse.text, forType: .string)

        // Hide panel and paste into previous app
        onPasteAndHide?()
    }

    func claudeCopyLastResponse() {
        if let last = claudeMessages.last(where: { $0.role == .assistant }) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(last.text, forType: .string)
        }
    }

    // MARK: - Command Ranking

    func incrementCommandRanking(_ name: String) {
        let key = "cmd:\(name)"
        let _ = rc_increment_ranking(key)
    }

    func commandRanking(for name: String) -> Int {
        let key = "cmd:\(name)"
        return Int(rc_get_ranking(key))
    }

    // MARK: - Focus

    /// Force focus on the first visible, editable text field.
    /// SwiftUI @FocusState doesn't work reliably with NSPanel + nonActivatingPanel,
    /// so we use AppKit directly. Retries up to 3 times with short delays to handle
    /// SwiftUI render lag (e.g. conditional view mounting or .disabled toggling).
    func focusFilterField(then completion: (() -> Void)? = nil) {
        func tryFocus(attempts: Int) {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let window = NSApp.keyWindow,
                   let textField = Self.findTextField(in: window.contentView) {
                    window.makeFirstResponder(textField)
                    completion?()
                } else {
                    tryFocus(attempts: attempts - 1)
                }
            }
        }
        tryFocus(attempts: 3)
    }

    private static func findTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable {
            return tf
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Private

    private func loadAppIcon(path: String) -> NSImage? {
        if let cached = iconCache[path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        iconCache[path] = icon
        return icon
    }

    private func startClaude(prompt: String) {
        query = prompt
        searchMode = .claude
        claudeAsk()
    }
}
