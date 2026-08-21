import AppKit
import Foundation
import AintoCore
import QuickLookUI
import UniformTypeIdentifiers

struct FileSearchItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: String { url.path }
    var title: String { url.lastPathComponent }
    var subtitle: String { url.deletingLastPathComponent().path }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Owns one cancellable Spotlight query at a time and publishes only results
/// from the latest generation.
@MainActor
final class FileSearchService: NSObject, ObservableObject {
    @Published var queryText: String = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [FileSearchItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    @Published var selectedIndex = 0
    var onOpen: (() -> Void)?

    private var metadataQuery: NSMetadataQuery?
    private var debounceWork: DispatchWorkItem?
    private var searchPaths: [String] = []
    private var allLocations = false
    private var includeHidden = false
    private var configurationLoaded = false

    func reloadConfiguration() {
        guard let cString = rc_config_load() else {
            configurationLoaded = false
            searchPaths = []
            allLocations = false
            errorMessage = "File Search settings could not be loaded. Check config.toml in Settings."
            return
        }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            configurationLoaded = false
            searchPaths = []
            allLocations = false
            errorMessage = "File Search settings could not be loaded. Check config.toml in Settings."
            return
        }
        searchPaths = (config["file_search_paths"] as? [String])?
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { !$0.isEmpty } ?? []
        allLocations = config["file_search_all_locations"] as? Bool ?? false
        includeHidden = config["file_search_include_hidden"] as? Bool ?? false
        configurationLoaded = true
        errorMessage = allLocations || !searchPaths.isEmpty
            ? nil
            : "Choose at least one File Search folder in Settings."
    }

    func clear() {
        queryText = ""
        cancelQuery()
        results = []
        selectedIndex = 0
        errorMessage = nil
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(selectedIndex + offset, results.count - 1))
    }

    func openSelected() {
        guard results.indices.contains(selectedIndex),
              openIfStillEligible(results[selectedIndex].url)
        else { return }
        onOpen?()
    }

    func actions(for item: FileSearchItem) -> [ActionItem] {
        let url = item.url
        return [
            ActionItem(title: "Open", icon: "arrow.up.forward.app", shortcut: "↵") { [weak self] in
                _ = self?.openIfStillEligible(url)
            },
            ActionItem(title: "Show in Finder", icon: "folder", shortcut: nil) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            ActionItem(title: "Quick Look", icon: "eye", shortcut: nil) { [weak self] in
                guard self?.eligibleItem(at: url) != nil else { return }
                QuickLookPreviewController.shared.preview(url)
            },
            ActionItem(title: "Copy Path", icon: "doc.on.doc", shortcut: nil) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            },
            ActionItem(title: "Open With…", icon: "square.and.arrow.up", shortcut: nil) { [weak self] in
                guard self?.eligibleItem(at: url) != nil else { return }
                Self.chooseApplicationAndOpen(url)
            }
        ]
    }

    private func scheduleSearch() {
        // Stop the previous Spotlight query immediately. Otherwise it can finish
        // during the debounce interval and briefly publish stale results.
        cancelQuery()
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            selectedIndex = 0
            return
        }
        guard configurationLoaded, allLocations || !searchPaths.isEmpty else {
            results = []
            selectedIndex = 0
            if errorMessage == nil {
                errorMessage = "Choose at least one File Search folder in Settings."
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.startSearch(trimmed)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func startSearch(_ text: String) {
        guard text == queryText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        cancelQuery()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        query.sortDescriptors = [
            NSSortDescriptor(
                key: NSMetadataItemFSNameKey,
                ascending: true,
                selector: #selector(NSString.localizedStandardCompare(_:))
            )
        ]
        if allLocations {
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
        } else {
            query.searchScopes = searchPaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        metadataQuery = query
        query.operationQueue = .main
        isSearching = true
        errorMessage = nil
        guard query.start() else {
            isSearching = false
            errorMessage = "Spotlight search could not start."
            stop(query)
            return
        }
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery,
              query === metadataQuery else { return }
        query.disableUpdates()
        let items = query.results.compactMap { result -> FileSearchItem? in
            guard let metadata = result as? NSMetadataItem,
                  let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String
            else { return nil }
            return eligibleItem(at: URL(fileURLWithPath: path))
        }
        query.enableUpdates()
        results = Array(items
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .prefix(100))
        selectedIndex = 0
        isSearching = false
        stop(query)
    }

    func eligibleItem(at url: URL) -> FileSearchItem? {
        let standardizedURL = url.standardizedFileURL
        let resolvedURL = standardizedURL.resolvingSymlinksInPath()
        guard isWithinConfiguredScope(resolvedURL) else { return nil }
        if resolvedURL.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return nil
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isExecutableKey]
        guard let values = try? resolvedURL.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = values.isDirectory == true
        guard isDirectory || values.isRegularFile == true else { return nil }
        let hasHiddenComponent = resolvedURL.pathComponents.contains { component in
            component.hasPrefix(".") && component != "." && component != ".."
        }
        if !includeHidden && (values.isHidden == true || hasHiddenComponent) { return nil }
        let isExecutable = values.isExecutable == true
            || FileManager.default.isExecutableFile(atPath: resolvedURL.path)
        if !isDirectory && isExecutable { return nil }
        return FileSearchItem(url: standardizedURL, isDirectory: isDirectory)
    }

    private func isWithinConfiguredScope(_ url: URL) -> Bool {
        guard !allLocations else { return true }
        let candidate = url.path
        return searchPaths.contains { scopePath in
            candidate == scopePath || candidate.hasPrefix(scopePath.hasSuffix("/") ? scopePath : scopePath + "/")
        }
    }

    @discardableResult
    private func openIfStillEligible(_ url: URL) -> Bool {
        guard let item = eligibleItem(at: url) else {
            results.removeAll { $0.url == url }
            selectedIndex = min(selectedIndex, max(0, results.count - 1))
            errorMessage = "The item is no longer eligible for File Search."
            return false
        }
        guard NSWorkspace.shared.open(item.url) else {
            errorMessage = "The item could not be opened."
            return false
        }
        return true
    }

    private func cancelQuery() {
        debounceWork?.cancel()
        debounceWork = nil
        if let query = metadataQuery { stop(query) }
        metadataQuery = nil
        isSearching = false
    }

    private func stop(_ query: NSMetadataQuery) {
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        query.stop()
        if metadataQuery === query { metadataQuery = nil }
    }

    private static func chooseApplicationAndOpen(_ url: URL) {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let applicationURL = panel.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: configuration
        )
    }
}

@MainActor
private final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookPreviewController()
    private var url: URL?

    func preview(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
