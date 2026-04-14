import SwiftUI
import AppKit
import AintoCore

/// Main search view — glassmorphism style matching modern macOS.
struct MainView: View {
    @ObservedObject var viewModel: SearchViewModel

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
        .background {
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.3),
                            Color.white.opacity(0.1),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        }
        .shadow(color: .black.opacity(0.3), radius: 40, x: 0, y: 20)
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
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

                // Mode indicator
                HStack(spacing: 4) {
                    Text(viewModel.searchMode == .claude ? "Search" : "AI mode")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("Tab")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .onAppear {
                viewModel.focusFilterField()
            }

            // Results list (hidden in Claude mode)
            if !viewModel.results.isEmpty && viewModel.searchMode == .apps {
                Divider()
                    .opacity(0.5)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
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
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: viewModel.selectedIndex) { _, newIndex in
                        if newIndex < viewModel.results.count {
                            proxy.scrollTo(viewModel.results[newIndex].id)
                        }
                    }
                }
            }

            // Footer
            Divider()
                .opacity(0.3)
            HStack {
                if !viewModel.query.isEmpty && viewModel.searchMode == .apps {
                    Text(viewModel.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 12) {
                    if !viewModel.results.isEmpty && viewModel.searchMode == .apps {
                        KeyHint(keys: ["⌘", "K"], label: "actions")
                        KeyHint(keys: ["↑", "↓"], label: "navigate")
                        KeyHint(keys: ["↵"], label: "open")
                    }
                    if !viewModel.query.isEmpty {
                        KeyHint(keys: ["esc"], label: "clear")
                    }
                    KeyHint(keys: ["Tab"], label: "AI mode")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
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
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

/// Keyboard shortcut hint badge.
struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
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
