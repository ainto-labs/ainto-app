import SwiftUI
import AppKit
import AintoCore

/// Main search view — glassmorphism style matching modern macOS.
struct MainView: View {
    @ObservedObject var viewModel: SearchViewModel
    /// Top row of the visible window of results.
    @State private var firstVisibleResult = 0

    /// Scrolls by whole rows, and only once the selection leaves the visible
    /// window, so a row is never left half under the header or the footer.
    private func scrollToKeepVisible(_ index: Int, proxy: ScrollViewProxy) {
        guard index < viewModel.results.count,
              let first = Theme.firstVisibleRow(keeping: index, from: firstVisibleResult)
        else { return }
        firstVisibleResult = first
        proxy.scrollTo(viewModel.results[first].id, anchor: .top)
    }

    var body: some View {
        Group {
            switch viewModel.page {
            case .main:
                mainSearchView
            case .clipboard:
                ClipboardView(viewModel: viewModel)
            case .snippets:
                SnippetView(viewModel: viewModel)
            case .aiCommands:
                AICommandView(viewModel: viewModel)
            case .claude:
                ClaudeView(viewModel: viewModel)
            }
        }
        .panelChrome()
    }

    private var mainSearchView: some View {
        VStack(spacing: 0) {
            // Search input
            HStack(spacing: 14) {
                if viewModel.searchMode == .claude {
                    ClaudeIcon(size: 22)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 20, weight: .medium))
                }

                TextField(
                    viewModel.searchMode == .claude ? "Ask Claude anything..." : "Search...",
                    text: $viewModel.query
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .regular))
                    .onSubmit {
                        viewModel.openSelected()
                    }

                Spacer()

                // Mode indicator — hidden when AI is disabled
                if viewModel.aiEnabled {
                    HStack(spacing: 6) {
                        Text(viewModel.searchMode == .claude ? "Search" : "AI mode")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Keycap(key: "Tab")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .onAppear {
                viewModel.focusFilterField()
            }

            // Results list (hidden in Claude mode)
            if !viewModel.results.isEmpty && viewModel.searchMode == .apps {
                Hairline()

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: Theme.rowSpacing) {
                            ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                                ResultRow(
                                    result: result,
                                    isSelected: index == viewModel.selectedIndex
                                )
                                .id(result.id)
                                .onTapGesture(count: 2) {
                                    viewModel.selectedIndex = index
                                    viewModel.openSelected()
                                }
                                .onTapGesture(count: 1) {
                                    viewModel.selectedIndex = index
                                }
                                .contextMenu {
                                    ForEach(result.actions) { action in
                                        Button(action: {
                                            action.action()
                                        }) {
                                            Label(action.title, systemImage: action.icon)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Margins rather than padding, so scrolling to a row keeps
                    // the gap above it instead of tucking it under the header.
                    .contentMargins(.vertical, Theme.rowInset, for: .scrollContent)
                    .clipToListMargins()
                    .frame(maxHeight: Theme.resultListMaxHeight)
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        scrollToKeepVisible(newIndex, proxy: proxy)
                    }
                    .onChange(of: viewModel.results.first?.id) { _, _ in
                        firstVisibleResult = 0
                    }
                }
            }

            // Footer
            HStack {
                if !viewModel.query.isEmpty && viewModel.searchMode == .apps {
                    Text(viewModel.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let version = viewModel.pendingUpdateVersion {
                    Button {
                        viewModel.onShowUpdate?()
                    } label: {
                        Label("Ainto \(version) is available", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 12) {
                    if !viewModel.currentActions.isEmpty && viewModel.searchMode == .apps {
                        KeyHint(keys: ["⌘", "K"], label: "actions")
                    }
                    if !viewModel.results.isEmpty && viewModel.searchMode == .apps {
                        KeyHint(keys: ["↑", "↓"], label: "navigate")
                        KeyHint(keys: ["↵"], label: "open")
                    }
                    if !viewModel.query.isEmpty {
                        KeyHint(keys: ["esc"], label: "clear")
                    }
                    if viewModel.aiEnabled {
                        KeyHint(keys: ["Tab"], label: "AI mode")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .barBackground()
        }
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: viewModel.query) { _, newValue in
            viewModel.performSearch(query: newValue)
        }
        .onChange(of: viewModel.shouldSelectAll) { _, shouldSelect in
            if shouldSelect {
                viewModel.focusFilterField(then: {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                })
                viewModel.shouldSelectAll = false
            }
        }
    }
}

/// A single search result row.
struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            // App icon
            Image(nsImage: result.displayIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.resultRowHeight)
        .background {
            if isSelected {
                SelectionBackground()
            }
        }
        .padding(.horizontal, Theme.rowInset)
        .contentShape(Rectangle())
    }
}

/// Keyboard shortcut hint badge.
struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Keycap(key: key)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
        }
    }
}

/// NSVisualEffectView wrapper for SwiftUI — real macOS vibrancy blur.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Claude Code icon using SF Symbol (no Anthropic logo — trademark restriction).
struct ClaudeIcon: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.7))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
    }
}
