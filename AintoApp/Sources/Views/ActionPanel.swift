import SwiftUI
import AppKit

/// Floating action panel — triggered by Cmd+K on a search result.
struct ActionPanelView: View {
    let title: String
    let actions: [ActionItem]
    var onDismiss: () -> Void = {}
    var selectedIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            // Action list
            VStack(spacing: 2) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    ActionRow(
                        action: action,
                        isSelected: index == selectedIndex
                    )
                    .onTapGesture {
                        action.action()
                        onDismiss()
                    }
                }
            }
            .padding(.vertical, 4)

            // Footer
            Divider().opacity(0.3)
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    KeyHint(keys: ["↑", "↓"], label: "navigate")
                    KeyHint(keys: ["↵"], label: "run")
                    KeyHint(keys: ["esc"], label: "close")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }

}

/// A single action row.
struct ActionRow: View {
    let action: ActionItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 12))
                .frame(width: 16)
                .foregroundStyle(isSelected ? .white : .secondary)

            Text(action.title)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .primary)

            Spacer()

            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .gray)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85))
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
