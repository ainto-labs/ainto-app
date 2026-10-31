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

            Hairline(inset: Theme.popoverRowInset)

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
            .barBackground(inset: Theme.popoverRowInset, radius: Theme.popoverRowRadius)
        }
        .frame(width: 260)
        .panelChrome()
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
                .foregroundStyle(.secondary)

            Text(action.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            Spacer()

            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                SelectionBackground(radius: Theme.popoverRowRadius)
            }
        }
        .padding(.horizontal, Theme.popoverRowInset)
        .contentShape(Rectangle())
    }
}
