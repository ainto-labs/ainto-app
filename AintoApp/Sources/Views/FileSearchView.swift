import AppKit
import SwiftUI

struct FileSearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var service: FileSearchService
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 16))

                TextField("Search files and folders…", text: $service.queryText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onAppear {
                        service.reloadConfiguration()
                        focused = true
                    }
                if service.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().opacity(0.5)

            if let error = service.errorMessage {
                ContentUnavailableView("Search unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(height: 330)
            } else if service.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "File Search",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Type a filename to search the folders configured in Settings.")
                )
                .frame(height: 330)
            } else if service.results.isEmpty && !service.isSearching {
                ContentUnavailableView("No files found", systemImage: "doc.text.magnifyingglass")
                    .frame(height: 330)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(service.results.enumerated()), id: \.element.id) { index, item in
                                FileSearchResultRow(item: item, selected: index == service.selectedIndex)
                                    .id(item.id)
                                    .onTapGesture(count: 2) {
                                        service.selectedIndex = index
                                        service.openSelected()
                                    }
                                    .onTapGesture {
                                        service.selectedIndex = index
                                    }
                                    .contextMenu {
                                        ForEach(service.actions(for: item)) { action in
                                            Button(action: action.action) {
                                                Label(action.title, systemImage: action.icon)
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 330)
                    .onChange(of: service.selectedIndex) { _, index in
                        guard service.results.indices.contains(index) else { return }
                        proxy.scrollTo(service.results[index].id)
                    }
                }
            }

            Divider().opacity(0.3)
            HStack {
                Text("\(service.results.count) results")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 12) {
                    KeyHint(keys: ["⌘", "K"], label: "actions")
                    KeyHint(keys: ["↑", "↓"], label: "navigate")
                    KeyHint(keys: ["↵"], label: "open")
                    KeyHint(keys: ["esc"], label: "back")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 680)
    }
}

private struct FileSearchResultRow: View {
    let item: FileSearchItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.isDirectory {
                Text("Folder")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.85))
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

struct SystemActionConfirmationView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: viewModel.pendingSystemAction?.icon ?? "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text(viewModel.isExecutingSystemAction
                 ? "Running \(viewModel.pendingSystemAction?.title ?? "System Action")…"
                 : "Confirm \(viewModel.pendingSystemAction?.title ?? "System Action")")
                .font(.system(size: 20, weight: .semibold))
            Text(viewModel.isExecutingSystemAction
                 ? "Ainto is asking macOS to perform this action."
                 : "This action affects your current macOS session.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let error = viewModel.systemActionError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            if viewModel.isExecutingSystemAction {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 12) {
                    Button("Cancel") { viewModel.cancelSystemAction() }
                        .keyboardShortcut(.cancelAction)
                    Button(viewModel.systemActionError == nil
                           ? (viewModel.pendingSystemAction?.title ?? "Continue")
                           : "Try Again", role: .destructive) {
                        viewModel.confirmSystemAction()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            Spacer()
            Divider().opacity(0.3)
            HStack {
                Spacer()
                if !viewModel.isExecutingSystemAction {
                    KeyHint(keys: ["↵"], label: viewModel.systemActionError == nil ? "confirm" : "retry")
                    KeyHint(keys: ["esc"], label: "cancel")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(width: 680, height: 300)
    }
}
