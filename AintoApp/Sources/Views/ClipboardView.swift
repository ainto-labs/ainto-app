import SwiftUI
import AppKit

/// Type filter for clipboard items.
enum ClipboardTypeFilter: String, CaseIterable {
    case all = "All Types"
    case text = "Text Only"
    case images = "Images Only"
    case files = "Files Only"
}

/// Clipboard history sub-page — Raycast-style split pane.
struct ClipboardView: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isFilterFocused: Bool
    /// Debounced preview item — avoids expensive ClipboardPreview re-renders
    /// (file I/O) during rapid up/down key navigation.
    @State private var previewItem: ClipboardItem?
    @State private var previewDebounceTask: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))

                TextField("Type to filter entries...", text: Binding(
                    get: { viewModel.clipboardFilter },
                    set: { viewModel.clipboardFilter = $0 }
                ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFilterFocused)
                    .onAppear { isFilterFocused = true }
                    .onChange(of: viewModel.debouncedClipboardFilter) { _, _ in
                        viewModel.clipboardSelectedIndex = 0
                    }

                Spacer()

                // Type filter
                Menu {
                    ForEach(ClipboardTypeFilter.allCases, id: \.self) { filter in
                        Button(action: { viewModel.clipboardTypeFilter = filter }) {
                            HStack {
                                Text(filter.rawValue)
                                if viewModel.clipboardTypeFilter == filter {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(viewModel.clipboardTypeFilter.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().opacity(0.5)

            if viewModel.filteredClipboardItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("No clipboard history")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 300)
            } else {
                HStack(spacing: 0) {
                    // Left: grouped item list (NSTableView for cell reuse + native selection)
                    ClipboardTableView(
                        items: viewModel.filteredClipboardItems,
                        groupedItems: viewModel.clipboardGroupedItems,
                        groupedKeys: viewModel.clipboardGroupedKeys,
                        indexMap: viewModel.clipboardIndexMap,
                        selectedIndex: $viewModel.clipboardSelectedIndex,
                        onSelectionChanged: { _ in schedulePreviewUpdate() },
                        onDoubleClick: { viewModel.openSelected() },
                        onScrolledNearBottom: { viewModel.loadMoreClipboardItems() },
                        viewModel: viewModel
                    )
                    .frame(width: 300)

                    Divider().opacity(0.3)

                    // Right: preview (debounced to avoid file I/O lag during rapid navigation)
                    ClipboardPreview(
                        item: previewItem,
                        onDelete: { id in viewModel.deleteClipboardItem(id: id) }
                    )
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 360)
                .onAppear { previewItem = selectedItem }
            }

            // Footer
            Divider().opacity(0.3)
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    KeyHint(keys: ["⌘", "⌫"], label: "delete")
                    KeyHint(keys: ["↵"], label: "paste")
                    KeyHint(keys: ["esc"], label: "back")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 680)
    }

    private var selectedItem: ClipboardItem? {
        let items = viewModel.filteredClipboardItems
        guard viewModel.clipboardSelectedIndex < items.count else { return nil }
        return items[viewModel.clipboardSelectedIndex]
    }

    private func schedulePreviewUpdate() {
        previewDebounceTask?.cancel()
        let task = DispatchWorkItem { [self] in
            previewItem = selectedItem
        }
        previewDebounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: task)
    }
}

/// Preview panel for the selected clipboard item.
/// Metadata (file size, dimensions, etc.) is loaded asynchronously to avoid
/// blocking the main thread during rapid selection changes.
struct ClipboardPreview: View {
    let item: ClipboardItem?
    let onDelete: (Int64) -> Void

    @State private var previewImage: NSImage?
    @State private var fileSize: String?
    @State private var fileModified: String?
    @State private var fileType: String?
    @State private var imageDimensions: String?
    @State private var imageSize: String?

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                // Content preview
                Group {
                    switch item.contentType {
                    case "image":
                        if let img = previewImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(12)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 50))
                                .foregroundStyle(.quaternary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case "file":
                        VStack(spacing: 12) {
                            if let img = previewImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 64, height: 64)
                            }
                            Text(item.displayTitle)
                                .font(.system(size: 14, weight: .medium))
                            if let path = item.filePath {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                    default:
                        ScrollView {
                            Text(item.text ?? "")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(12)
                                .textSelection(.enabled)
                        }
                    }
                }

                Divider().opacity(0.3)

                // Information
                VStack(alignment: .leading, spacing: 6) {
                    Text("Information")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if let app = item.sourceApp {
                        MetadataRow(label: "Source", value: appName(from: app))
                    }
                    MetadataRow(label: "Content type", value: item.contentTypeLabel)

                    switch item.contentType {
                    case "text":
                        if let text = item.text {
                            MetadataRow(label: "Characters", value: "\(text.count)")
                            MetadataRow(label: "Words", value: "\(text.split(separator: " ").count)")
                        }
                    case "file":
                        if let size = fileSize { MetadataRow(label: "Size", value: size) }
                        if let modified = fileModified { MetadataRow(label: "Modified", value: modified) }
                        if let type = fileType { MetadataRow(label: "Type", value: type) }
                    case "image":
                        if let dims = imageDimensions { MetadataRow(label: "Dimensions", value: dims) }
                        if let size = imageSize { MetadataRow(label: "Image size", value: size) }
                    default:
                        EmptyView()
                    }

                    MetadataRow(label: "Copied", value: item.relativeTime)
                    if item.copyCount > 1 {
                        MetadataRow(label: "Times", value: "\(item.copyCount)")
                    }
                }
                .padding(12)

                Divider().opacity(0.3)

                HStack {
                    Spacer()
                    Button(action: { onDelete(item.id) }) {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .task(id: item.id) {
                await loadMetadata(for: item)
            }
        } else {
            VStack {
                Image(systemName: "arrow.left")
                    .font(.system(size: 30))
                    .foregroundStyle(.quaternary)
                Text("Select an item")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadMetadata(for item: ClipboardItem) async {
        // Reset
        previewImage = nil
        fileSize = nil
        fileModified = nil
        fileType = nil
        imageDimensions = nil
        imageSize = nil

        // Load image/icon and metadata off main thread
        let capturedItem = item
        let result = await Task.detached { () -> PreviewMetadata in
            var meta = PreviewMetadata()
            meta.image = capturedItem.displayImage

            switch capturedItem.contentType {
            case "file":
                if let path = capturedItem.filePath {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                        if let s = attrs[.size] as? UInt64 {
                            let kb = Double(s) / 1024
                            meta.fileSize = kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb / 1024)
                        }
                        if let d = attrs[.modificationDate] as? Date {
                            meta.fileModified = d.formatted(date: .abbreviated, time: .shortened)
                        }
                    }
                    if let ct = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey]).contentType {
                        meta.fileType = ct.localizedDescription ?? ct.identifier
                    }
                }
            case "image":
                if let img = meta.image {
                    meta.imageDimensions = "\(Int(img.size.width))×\(Int(img.size.height))"
                }
                if let path = capturedItem.imagePath,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let s = attrs[.size] as? UInt64 {
                    let kb = Double(s) / 1024
                    meta.imageSize = kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb / 1024)
                }
            default:
                break
            }
            return meta
        }.value

        guard !Task.isCancelled else { return }
        previewImage = result.image
        fileSize = result.fileSize
        fileModified = result.fileModified
        fileType = result.fileType
        imageDimensions = result.imageDimensions
        imageSize = result.imageSize
    }

    private func appName(from bundleId: String) -> String {
        bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}

/// Holds preview metadata loaded off the main thread.
private struct PreviewMetadata: @unchecked Sendable {
    var image: NSImage?
    var fileSize: String?
    var fileModified: String?
    var fileType: String?
    var imageDimensions: String?
    var imageSize: String?
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }
}
