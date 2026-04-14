import SwiftUI
import AppKit

/// Snippet management sub-page — list + preview/edit.
struct SnippetView: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isEditingSnippet, viewModel.editingSnippet != nil {
                // Edit mode: title bar instead of filter
                HStack(spacing: 12) {
                    Button(action: { viewModel.cancelEditingSnippet() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "text.quote")
                        .foregroundStyle(.red)
                        .font(.system(size: 16))

                    Text(isNewSnippet ? "Create Snippet" : "Edit Snippet")
                        .font(.system(size: 16, weight: .medium))

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().opacity(0.5)

                SnippetEditForm(viewModel: viewModel)
            } else {
                // List mode: filter bar
                HStack(spacing: 12) {
                    Button(action: { viewModel.goBack() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "text.quote")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))

                    TextField("Filter snippets...", text: $viewModel.snippetFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isFilterFocused)
                        .onAppear { isFilterFocused = true }
                        .onChange(of: viewModel.snippetFilter) { _, _ in
                            viewModel.snippetSelectedIndex = 0
                        }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().opacity(0.5)

                if viewModel.filteredSnippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("No snippets")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("Click + to create one")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 300)
            } else {
                HStack(spacing: 0) {
                    // Left: snippet list
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(viewModel.filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                                    SnippetItemRow(
                                        snippet: snippet,
                                        isSelected: index == viewModel.snippetSelectedIndex
                                    )
                                    .id(snippet.id)
                                    .onTapGesture(count: 2) {
                                        viewModel.snippetSelectedIndex = index
                                        viewModel.expandSelectedSnippet()
                                    }
                                    .onTapGesture(count: 1) {
                                        viewModel.snippetSelectedIndex = index
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onChange(of: viewModel.snippetSelectedIndex) { _, newIndex in
                            let items = viewModel.filteredSnippets
                            if newIndex < items.count {
                                proxy.scrollTo(items[newIndex].id)
                            }
                        }
                    }
                    .frame(width: 280)

                    Divider().opacity(0.3)

                    // Right: preview
                    SnippetPreview(
                        snippet: selectedSnippet,
                        onEdit: { viewModel.editSelectedSnippet() },
                        onDelete: { id in viewModel.deleteSnippet(id: id) }
                    )
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 360)
                }
            }

            // Footer
            Divider().opacity(0.3)
            HStack {
                if !viewModel.isEditingSnippet {
                    Text("\(viewModel.filteredSnippets.count) snippets")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 12) {
                    if viewModel.isEditingSnippet {
                        KeyHint(keys: ["⌘", "↵"], label: "save")
                        KeyHint(keys: ["esc"], label: "cancel")
                    } else {
                        KeyHint(keys: ["⌘", "N"], label: "new")
                        KeyHint(keys: ["⌘", "E"], label: "edit")
                        KeyHint(keys: ["↵"], label: "paste")
                        KeyHint(keys: ["esc"], label: "back")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 680)
    }

    private var isNewSnippet: Bool {
        guard let editing = viewModel.editingSnippet else { return true }
        return !viewModel.snippets.contains(where: { $0.id == editing.id })
    }

    private var selectedSnippet: SnippetItem? {
        let items = viewModel.filteredSnippets
        guard viewModel.snippetSelectedIndex < items.count else { return nil }
        return items[viewModel.snippetSelectedIndex]
    }
}

/// A row in the snippet list.
struct SnippetItemRow: View {
    let snippet: SnippetItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.quote")
                .frame(width: 24, height: 24)
                .foregroundStyle(isSelected ? .white : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(snippet.keyword)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .gray)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

/// Preview panel for the selected snippet.
struct SnippetPreview: View {
    let snippet: SnippetItem?
    let onEdit: () -> Void
    let onDelete: (String) -> Void

    var body: some View {
        if let snippet {
            VStack(spacing: 0) {
                // Expansion preview
                ScrollView {
                    Text(snippet.expansion)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .textSelection(.enabled)
                }

                Divider().opacity(0.3)

                // Info
                VStack(alignment: .leading, spacing: 6) {
                    Text("Information")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    MetadataRow(label: "Name", value: snippet.name)
                    MetadataRow(label: "Keyword", value: snippet.keyword)
                    MetadataRow(label: "Characters", value: "\(snippet.expansion.count)")
                }
                .padding(12)

                Divider().opacity(0.3)

                // Actions
                HStack {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: { onDelete(snippet.id) }) {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else {
            VStack {
                Image(systemName: "text.quote")
                    .font(.system(size: 30))
                    .foregroundStyle(.quaternary)
                Text("Select a snippet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Raycast-style form for creating/editing a snippet.
struct SnippetEditForm: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Form fields
            ScrollView {
                VStack(spacing: 20) {
                    // Name — auto focus via AppKit
                    FormRow(label: "Name") {
                        TextField("Snippet name", text: binding(\.name))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .onAppear {
                        // Focus the name field after render
                        viewModel.focusFilterField()
                    }

                    // Snippet (expansion text)
                    FormRow(label: "Snippet") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: binding(\.expansion))
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 120)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text("Include **Dynamic Placeholders** for context like the copied text or the current date: `{date}` `{time}` `{clipboard}` `{uuid}`")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Keyword
                    FormRow(label: "Keyword") {
                        TextField("Optional keyword", text: binding(\.keyword))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
            }

        }
        .frame(height: 420)
    }

    private func binding(_ keyPath: WritableKeyPath<SnippetItem, String>) -> Binding<String> {
        Binding(
            get: { viewModel.editingSnippet?[keyPath: keyPath] ?? "" },
            set: { viewModel.editingSnippet?[keyPath: keyPath] = $0 }
        )
    }
}

/// A form row with left label and right content, matching Raycast's layout.
struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
                .padding(.top, 8)

            content()
        }
    }
}
