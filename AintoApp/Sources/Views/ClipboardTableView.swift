import AppKit
import SwiftUI

/// NSTableView-based clipboard list with cell reuse for smooth scrolling.
/// Replaces SwiftUI LazyVStack to eliminate re-render overhead on selection changes.
struct ClipboardTableView: NSViewRepresentable {
    let items: [ClipboardItem]
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
        // Overlay scrollers never draw a track, even with "Show scroll bars: Always".
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // The highlight sits 1pt inside each row, so these leave rowInset
        // between it and the list's top and bottom, like the SwiftUI lists.
        let margin = Theme.rowInset - Theme.rowSpacing / 2
        scrollView.contentInsets = NSEdgeInsets(top: margin, left: 0, bottom: margin, right: 0)

        let tableView = NSTableView()
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none // We draw our own highlight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = Theme.clipboardRowHeight
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

        // Observe scroll position so mouse/trackpad scrolling (not just arrow
        // keys) triggers pagination load-more when nearing the bottom.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Register callback so arrow keys bypass SwiftUI and move NSTableView directly
        let coordinator = context.coordinator
        // Once the table has laid out, start on a row boundary below the top inset.
        let initialIndex = selectedIndex
        DispatchQueue.main.async {
            coordinator.scrollToKeepVisible(initialIndex)
        }
        viewModel.onClipboardSelectionMove = { [weak coordinator] newIndex in
            coordinator?.moveToIndex(newIndex)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = context.coordinator.tableView else { return }
        let coordinator = context.coordinator

        // Compare item IDs to detect data changes (count alone misses delete+pagination backfill)
        let oldIDs = coordinator.parent.items.map(\.id)
        let newIDs = items.map(\.id)
        let dataChanged = oldIDs != newIDs
        // A pagination backfill appends to the bottom: the old IDs stay as a
        // prefix and more are added. Those rows don't move, so we must preserve
        // the scroll position instead of jumping to the selected row.
        let isAppend = newIDs.count > oldIDs.count && Array(newIDs.prefix(oldIDs.count)) == oldIDs

        coordinator.parent = self

        if dataChanged {
            if isAppend {
                let savedOrigin = scrollView.contentView.bounds.origin
                tableView.reloadData()
                tableView.layoutSubtreeIfNeeded()
                scrollView.contentView.scroll(to: savedOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                tableView.reloadData()
                // After a reset (filter/delete), sync selection into view
                if selectedIndex < items.count {
                    coordinator.suppressSelectionCallback = true
                    tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                    coordinator.scrollToKeepVisible(selectedIndex)
                    coordinator.suppressSelectionCallback = false
                }
            }
        }
        // Selection changes are handled by onClipboardSelectionMove callback,
        // not through SwiftUI updateNSView, to avoid re-render overhead.
    }

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ClipboardTableView
        weak var tableView: NSTableView?
        var suppressSelectionCallback = false

        init(_ parent: ClipboardTableView) {
            self.parent = parent
            super.init()
        }

        // MARK: - DataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        // MARK: - Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.items.count else { return nil }
            return makeItemView(item: parent.items[row], isSelected: row == parent.selectedIndex, tableView: tableView)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelectionCallback else { return }
            let row = tableView?.selectedRow ?? -1
            guard row >= 0, row < parent.items.count else { return }
            parent.selectedIndex = row
            // Mouse clicks change the selection through here (arrow keys go
            // through moveToIndex). The native selection highlight is disabled,
            // so update our custom highlight box ourselves, or a click leaves
            // no visible selection.
            refreshVisibleHighlights(selectedRow: row)
            parent.onSelectionChanged?(row)
        }

        /// Repaint the custom highlight on the visible cells so exactly the
        /// selected row is highlighted. Touches only on-screen cells and never
        /// reloads (which would re-read the icon from disk).
        private func refreshVisibleHighlights(selectedRow: Int) {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for r in visible.location..<(visible.location + visible.length) {
                guard let cell = tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? ClipboardCellView else { continue }
                cell.updateHighlight(isSelected: r == selectedRow)
            }
        }

        /// Move selection directly in NSTableView, called from
        /// ViewModel.moveSelection via callback, bypassing SwiftUI entirely.
        func moveToIndex(_ row: Int) {
            guard let tableView, row < parent.items.count else { return }

            // First move: selectedRow is -1, fall back to row 0
            let previousRow = max(tableView.selectedRow, 0)
            suppressSelectionCallback = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollToKeepVisible(row)
            suppressSelectionCallback = false

            // Update highlight only, no reloadData (avoids displayImage I/O)
            if let cell = tableView.view(atColumn: 0, row: previousRow, makeIfNecessary: false) as? ClipboardCellView {
                cell.updateHighlight(isSelected: false)
            }
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipboardCellView {
                cell.updateHighlight(isSelected: true)
            }

            parent.onSelectionChanged?(row)

            // Trigger load-more when near bottom (within 5 items)
            if row >= parent.items.count - 5 {
                parent.onScrolledNearBottom?()
            }
        }

        /// Scrolls a whole row at a time, and only once `row` leaves the
        /// visible window, matching the SwiftUI lists. Also snaps back to a
        /// row boundary, since the list opens, and a trackpad can leave it,
        /// partway through a row.
        func scrollToKeepVisible(_ row: Int) {
            guard let tableView, let scrollView = tableView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            let topInset = scrollView.contentInsets.top
            let firstVisible = max(0, Int(((clip.bounds.minY + topInset) / tableView.rowHeight).rounded()))
            let first = Theme.firstVisibleRow(keeping: row, from: firstVisible) ?? firstVisible
            let target = NSPoint(x: 0, y: CGFloat(first) * tableView.rowHeight - topInset)
            guard clip.bounds.origin != target else { return }
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }

        /// Mouse/trackpad scroll handler: load the next page when the visible
        /// area nears the bottom (within ~2 rows). loadMoreClipboardItems guards
        /// on clipboardHasMore, so firing repeatedly is harmless.
        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let documentView = clipView.documentView else { return }
            let contentHeight = documentView.bounds.height
            guard contentHeight > 0 else { return }
            let threshold = (tableView?.rowHeight ?? Theme.clipboardRowHeight) * 2
            if clipView.bounds.maxY >= contentHeight - threshold {
                parent.onScrolledNearBottom?()
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < parent.items.count else { return }
            parent.selectedIndex = row
            parent.onDoubleClick()
        }

        // MARK: - Cell views

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
        backgroundBox.cornerRadius = Theme.rowRadius
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

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
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
            backgroundBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.rowInset),
            backgroundBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.rowInset),
            backgroundBox.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            backgroundBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.rowInset + 10),
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

    /// Updates only colors and the highlight, never the image. Matches the SwiftUI
    /// `SelectionBackground` in Theme.swift.
    func updateHighlight(isSelected: Bool) {
        if isSymbolIcon {
            iconView.contentTintColor = .secondaryLabelColor
        }
        titleLabel.textColor = .labelColor
        subtitleLabel.textColor = .secondaryLabelColor
        backgroundBox.fillColor = isSelected ? Theme.nsSelectionFill : .clear
        backgroundBox.borderColor = Theme.nsSelectionStroke
        backgroundBox.borderWidth = isSelected ? 0.5 : 0
    }
}
