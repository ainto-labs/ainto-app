import AppKit
import SwiftUI

/// NSTableView-based clipboard list with cell reuse for smooth scrolling.
/// Replaces SwiftUI LazyVStack to eliminate re-render overhead on selection changes.
struct ClipboardTableView: NSViewRepresentable {
    let items: [ClipboardItem]
    let groupedItems: [String: [ClipboardItem]]
    let groupedKeys: [String]
    let indexMap: [Int64: Int]
    @Binding var selectedIndex: Int
    var onSelectionChanged: ((Int) -> Void)?
    var onDoubleClick: () -> Void
    var onScrolledNearBottom: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// ViewModel reference for registering the selection move callback.
    var viewModel: SearchViewModel

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none // We draw our own highlight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 44
        tableView.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.isEditable = false
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.target = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        // Register callback so arrow keys bypass SwiftUI and move NSTableView directly
        let coordinator = context.coordinator
        viewModel.onClipboardSelectionMove = { [weak coordinator] newIndex in
            coordinator?.moveToIndex(newIndex)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView else { return }
        let coordinator = context.coordinator

        // Compare item IDs to detect data changes (count alone misses delete+pagination backfill)
        let dataChanged = coordinator.parent.items.map(\.id) != items.map(\.id)

        coordinator.parent = self

        if dataChanged {
            tableView.reloadData()
            // After data reload, sync selection
            let row = coordinator.flatRow(for: selectedIndex)
            if row >= 0 {
                coordinator.suppressSelectionCallback = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
                coordinator.suppressSelectionCallback = false
            }
        }
        // Selection changes are handled by onClipboardSelectionMove callback,
        // not through SwiftUI updateNSView, to avoid re-render overhead.
    }

    // MARK: - Flat row model

    /// Each row in the table is either a group header or an item.
    enum FlatRow {
        case header(String)
        case item(ClipboardItem, Int) // item + global index
    }

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ClipboardTableView
        weak var tableView: NSTableView?
        var suppressSelectionCallback = false
        private var flatRows: [FlatRow] = []

        init(_ parent: ClipboardTableView) {
            self.parent = parent
            super.init()
            rebuildFlatRows()
        }

        func rebuildFlatRows() {
            var rows: [FlatRow] = []
            for key in parent.groupedKeys {
                rows.append(.header(key))
                if let items = parent.groupedItems[key] {
                    for item in items {
                        let globalIdx = parent.indexMap[item.id] ?? 0
                        rows.append(.item(item, globalIdx))
                    }
                }
            }
            flatRows = rows
        }

        /// Convert a global item index to a flat table row index.
        func flatRow(for globalIndex: Int) -> Int {
            guard globalIndex < parent.items.count else { return -1 }
            let targetId = parent.items[globalIndex].id
            return flatRows.firstIndex(where: {
                if case .item(let item, _) = $0 { return item.id == targetId }
                return false
            }) ?? -1
        }

        // MARK: - DataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rebuildFlatRows()
            return flatRows.count
        }

        // MARK: - Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < flatRows.count else { return nil }

            switch flatRows[row] {
            case .header(let title):
                return makeHeaderView(title: title, tableView: tableView)
            case .item(let item, let globalIndex):
                let isSelected = globalIndex == parent.selectedIndex
                return makeItemView(item: item, isSelected: isSelected, tableView: tableView)
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < flatRows.count else { return 44 }
            switch flatRows[row] {
            case .header: return 24
            case .item: return 44
            }
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard row < flatRows.count else { return false }
            if case .header = flatRows[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row < flatRows.count else { return false }
            if case .header = flatRows[row] { return false }
            return true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            let row = tableView?.selectedRow ?? -1
            guard row >= 0, row < flatRows.count else { return }
            if case .item(_, let globalIndex) = flatRows[row] {
                parent.selectedIndex = globalIndex
                parent.onSelectionChanged?(globalIndex)
            }
        }

        /// Move selection directly in NSTableView — called from ViewModel.moveSelection
        /// via callback, bypassing SwiftUI entirely.
        func moveToIndex(_ globalIndex: Int) {
            guard let tableView else { return }
            let row = flatRow(for: globalIndex)
            guard row >= 0 else { return }

            // First move: selectedRow is -1, fall back to row for index 0
            let previousRow = tableView.selectedRow >= 0
                ? tableView.selectedRow
                : flatRow(for: 0)
            suppressSelectionCallback = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            suppressSelectionCallback = false

            // Update highlight only — no reloadData (avoids displayImage I/O)
            if previousRow >= 0, let cell = tableView.view(atColumn: 0, row: previousRow, makeIfNecessary: false) as? ClipboardCellView {
                cell.updateHighlight(isSelected: false)
            }
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipboardCellView {
                cell.updateHighlight(isSelected: true)
            }

            parent.onSelectionChanged?(globalIndex)

            // Trigger load-more when near bottom (within 5 items)
            if globalIndex >= parent.items.count - 5 {
                parent.onScrolledNearBottom?()
            }
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < flatRows.count else { return }
            if case .item(_, let globalIndex) = flatRows[row] {
                parent.selectedIndex = globalIndex
                parent.onDoubleClick()
            }
        }

        // MARK: - Cell views

        private func makeHeaderView(title: String, tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("header")
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
                reused.stringValue = title
                return reused
            }
            let label = NSTextField(labelWithString: title)
            label.identifier = id
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        private func makeItemView(item: ClipboardItem, isSelected: Bool, tableView: NSTableView) -> NSView {
            let id = NSUserInterfaceItemIdentifier("clipItem")
            let cell: ClipboardCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? ClipboardCellView {
                cell = reused
            } else {
                cell = ClipboardCellView()
                cell.identifier = id
            }
            cell.configure(item: item, isSelected: isSelected)
            return cell
        }
    }
}

// MARK: - Cell View

/// AppKit cell view with icon, title, subtitle — matches the SwiftUI ClipboardItemRow layout.
@MainActor
final class ClipboardCellView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let backgroundBox = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Background highlight
        backgroundBox.boxType = .custom
        backgroundBox.cornerRadius = 8
        backgroundBox.borderWidth = 0
        backgroundBox.fillColor = .clear
        backgroundBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundBox)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            backgroundBox.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    /// Whether the current icon is an SF Symbol (needs tint update on highlight change).
    private var isSymbolIcon = false

    func configure(item: ClipboardItem, isSelected: Bool) {
        // Icon (expensive — reads from disk)
        if let img = item.displayImage {
            iconView.image = img
            iconView.contentTintColor = nil
            isSymbolIcon = false
        } else {
            iconView.image = NSImage(systemSymbolName: item.iconName, accessibilityDescription: nil)
            isSymbolIcon = true
        }

        // Title
        titleLabel.stringValue = item.displayTitle

        // Subtitle
        var subtitle = item.relativeTime
        if let app = item.sourceApp {
            let appName = app.components(separatedBy: ".").last ?? app
            subtitle += "  \(appName)"
        }
        subtitleLabel.stringValue = subtitle

        updateHighlight(isSelected: isSelected)
    }

    /// Update only colors/highlight — no image reload.
    func updateHighlight(isSelected: Bool) {
        if isSymbolIcon {
            iconView.contentTintColor = isSelected ? .white : .secondaryLabelColor
        }
        titleLabel.textColor = isSelected ? .white : .labelColor
        subtitleLabel.textColor = isSelected ? .white.withAlphaComponent(0.7) : .gray
        backgroundBox.fillColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : .clear
    }
}
