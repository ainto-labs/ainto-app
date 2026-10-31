import SwiftUI
import AppKit

/// AI Commands management sub-page — mirrors SnippetView layout.
struct AICommandView: View {
    @ObservedObject var viewModel: SearchViewModel
    /// Top row of the visible window of the list.
    @State private var firstVisibleCommand = 0
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isEditingAICommand, viewModel.editingAICommand != nil {
                // Edit mode
                HStack(spacing: 12) {
                    Button(action: { viewModel.cancelEditingAICommand() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "sparkle")
                        .foregroundStyle(.purple)
                        .font(.system(size: 16))

                    Text(isNewCommand ? "Create AI Command" : "Edit AI Command")
                        .font(.system(size: 16, weight: .medium))

                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: Theme.searchBarHeight)

                Hairline()

                AICommandEditForm(viewModel: viewModel)
            } else {
                // List mode
                HStack(spacing: 12) {
                    Button(action: { viewModel.goBack() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "sparkle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))

                    TextField("Filter commands...", text: $viewModel.aiCommandFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($isFilterFocused)
                        .onAppear { isFilterFocused = true }
                        .onChange(of: viewModel.aiCommandFilter) { _, _ in
                            viewModel.aiCommandSelectedIndex = 0
                        }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: Theme.searchBarHeight)

                Hairline()

                if viewModel.filteredAICommands.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 40))
                            .foregroundStyle(.quaternary)
                        Text("No AI commands")
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
                        // Left: command list
                        ScrollViewReader { proxy in
                            ScrollView(showsIndicators: false) {
                                VStack(spacing: Theme.rowSpacing) {
                                    ForEach(Array(viewModel.filteredAICommands.enumerated()), id: \.element.id) { index, command in
                                        AICommandItemRow(
                                            command: command,
                                            isSelected: index == viewModel.aiCommandSelectedIndex
                                        )
                                        .id(command.id)
                                        .onTapGesture(count: 2) {
                                            viewModel.aiCommandSelectedIndex = index
                                            viewModel.openSelected()
                                        }
                                        .onTapGesture(count: 1) {
                                            viewModel.aiCommandSelectedIndex = index
                                        }
                                    }
                                }
                            }
                            .contentMargins(.vertical, Theme.rowInset, for: .scrollContent)
                            .clipToListMargins()
                            .onChange(of: viewModel.aiCommandSelectedIndex) { _, newIndex in
                                let items = viewModel.filteredAICommands
                                guard newIndex < items.count,
                                      let first = Theme.firstVisibleRow(keeping: newIndex, from: firstVisibleCommand)
                                else { return }
                                firstVisibleCommand = first
                                proxy.scrollTo(items[first].id, anchor: .top)
                            }
                            .onChange(of: viewModel.filteredAICommands.first?.id) { _, _ in
                                firstVisibleCommand = 0
                            }
                        }
                        .frame(width: 280)

                        // Right: preview
                        AICommandPreview(
                            command: selectedCommand,
                            onEdit: { viewModel.editSelectedAICommand() },
                            onDelete: { id in viewModel.deleteAICommand(id: id) }
                        )
                        .frame(maxWidth: .infinity)
                        .paneBackground()
                    }
                    .frame(height: Theme.splitListHeight)
                }
            }

            // Footer
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    if viewModel.isEditingAICommand {
                        KeyHint(keys: ["⌘", "↵"], label: "save")
                        KeyHint(keys: ["esc"], label: "cancel")
                    } else {
                        KeyHint(keys: ["⌘", "N"], label: "new")
                        KeyHint(keys: ["⌘", "E"], label: "edit")
                        KeyHint(keys: ["↵"], label: "run")
                        KeyHint(keys: ["esc"], label: "back")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .barBackground()
        }
        .frame(width: 680)
    }

    private var isNewCommand: Bool {
        guard let editing = viewModel.editingAICommand else { return true }
        return !viewModel.aiCommands.contains(where: { $0.id == editing.id })
    }

    private var selectedCommand: AICommand? {
        let items = viewModel.filteredAICommands
        guard viewModel.aiCommandSelectedIndex < items.count else { return nil }
        return items[viewModel.aiCommandSelectedIndex]
    }
}

/// A row in the AI command list.
struct AICommandItemRow: View {
    let command: AICommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.name.isEmpty ? "Untitled" : command.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(command.prompt.components(separatedBy: .newlines).last?.trimmingCharacters(in: .whitespaces).prefix(50) ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.listRowHeight)
        .background {
            if isSelected {
                SelectionBackground()
            }
        }
        .padding(.horizontal, Theme.rowInset)
        .contentShape(Rectangle())
    }
}

/// Preview panel for the selected AI command.
struct AICommandPreview: View {
    let command: AICommand?
    let onEdit: () -> Void
    let onDelete: (String) -> Void

    var body: some View {
        if let command {
            VStack(spacing: 0) {
                // Prompt preview
                ScrollView {
                    Text(command.prompt)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .textSelection(.enabled)
                }

                Hairline(inset: 12)

                // Info
                VStack(alignment: .leading, spacing: 6) {
                    Text("Information")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    MetadataRow(label: "Name", value: command.name)
                    MetadataRow(label: "Icon", value: command.icon)
                    if command.prompt.contains("{selection}") {
                        MetadataRow(label: "Input", value: "Selected text")
                    }
                }
                .padding(12)

                Hairline(inset: 12)

                // Actions
                HStack {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: { onDelete(command.id) }) {
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
                Image(systemName: "sparkle")
                    .font(.system(size: 30))
                    .foregroundStyle(.quaternary)
                Text("Select a command")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Edit form for AI commands.
struct AICommandEditForm: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Name
                    FormRow(label: "Name") {
                        TextField("Command name", text: binding(\.name))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }
                    .onAppear {
                        viewModel.focusFilterField()
                    }

                    // Icon (SF Symbol name)
                    FormRow(label: "Icon") {
                        TextField("SF Symbol name (e.g. sparkle)", text: binding(\.icon))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }

                    // Prompt
                    FormRow(label: "Prompt") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: binding(\.prompt))
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 160)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

                            Text("Use `{selection}` as placeholder for the selected text from the frontmost app.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(height: 420)
    }

    private func binding(_ keyPath: WritableKeyPath<AICommand, String>) -> Binding<String> {
        Binding(
            get: { viewModel.editingAICommand?[keyPath: keyPath] ?? "" },
            set: { viewModel.editingAICommand?[keyPath: keyPath] = $0 }
        )
    }
}
