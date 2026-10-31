import SwiftUI
import AppKit

/// Shared colors and shapes for the launcher surfaces, so every page picks
/// up the same look.
enum Theme {
    // Light mode needs much less tint than dark: the same amount on a bright
    // background stacks into muddy layers of gray.

    /// Neutral rather than accent: a saturated block outshouts the icon and
    /// text it is meant to frame, and forces the text to flip to white.
    static var nsSelectionFill: NSColor { tint(light: 0.07, dark: 0.22) }
    static var nsSelectionStroke: NSColor { tint(light: 0.06, dark: 0.1) }
    static let selectionFill = Color(nsColor: nsSelectionFill)
    static let selectionStroke = Color(nsColor: nsSelectionStroke)
    static let hairline = Color(nsColor: tint(light: 0.08, dark: 0.08))
    static let barFill = Color(nsColor: tint(light: 0.035, dark: 0.06))
    static let paneFill = Color(nsColor: tint(light: 0.03, dark: 0.045))
    static var nsPanelEdge: NSColor { tint(light: 0.12, dark: 0.15) }

    private static func tint(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark)
                : NSColor(white: 0, alpha: light)
        }
    }

    /// Window material behind every floating panel. HUD glass turns a murky
    /// gray in light mode, so light mode uses the brighter popover glass.
    static func panelMaterial(for scheme: ColorScheme) -> NSVisualEffectView.Material {
        scheme == .dark ? .hudWindow : .popover
    }
    static let panelSheen = LinearGradient(
        colors: [Color.white.opacity(0.06), Color.clear],
        startPoint: .top, endPoint: .bottom
    )

    // Corners are concentric, as in Spotlight: a row's radius is the panel's
    // radius minus the gap between them, so both curves run parallel.
    static let panelRadius: CGFloat = 24
    static let rowInset: CGFloat = 10
    static let rowRadius: CGFloat = panelRadius - rowInset

    static let popoverRadius: CGFloat = 16
    static let popoverRowInset: CGFloat = 6
    static let popoverRowRadius: CGFloat = popoverRadius - popoverRowInset

    /// Boxes inside a panel: previews, code blocks, message bubbles, fields.
    static let cardRadius: CGFloat = 10

    // Lists are sized to a whole number of rows and scroll a whole row at a
    // time, so a row is never left half under the header or the footer.
    static let rowSpacing: CGFloat = 2
    static let maxVisibleRows = 7

    static let resultRowHeight: CGFloat = 48
    static let resultListMaxHeight = listHeight(rowHeight: resultRowHeight)

    /// Rows in the lists beside a preview pane (snippets, AI commands).
    static let listRowHeight: CGFloat = 42
    static let splitListHeight = listHeight(rowHeight: listRowHeight)
    /// The clipboard's NSTableView rows carry the row spacing inside them.
    static let clipboardRowHeight: CGFloat = listRowHeight + rowSpacing

    private static func listHeight(rowHeight: CGFloat) -> CGFloat {
        rowInset * 2
            + rowHeight * CGFloat(maxVisibleRows)
            + rowSpacing * CGFloat(maxVisibleRows - 1)
    }

    /// The top row a list should scroll to so `index` stays inside the
    /// visible window that starts at `firstVisible`, or nil if it already is.
    static func firstVisibleRow(keeping index: Int, from firstVisible: Int) -> Int? {
        if index < firstVisible { return index }
        if index >= firstVisible + maxVisibleRows { return index - maxVisibleRows + 1 }
        return nil
    }
}

private struct PanelBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            VisualEffectBackground(
                material: Theme.panelMaterial(for: colorScheme),
                blendingMode: .behindWindow
            )
            Theme.panelSheen
        }
    }
}

/// Rounded highlight behind the selected row of a list.
struct SelectionBackground: View {
    var radius: CGFloat = Theme.rowRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Theme.selectionFill)
            .overlay(shape.strokeBorder(Theme.selectionStroke, lineWidth: 0.5))
    }
}

/// Soft separator, inset by default to line up with the row highlights.
struct Hairline: View {
    var inset: CGFloat = Theme.rowInset

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.horizontal, inset)
    }
}

extension Theme {
    /// Gives a floating panel window its rounded outline and edge.
    ///
    /// Both live on the window's content layer rather than in SwiftUI: the
    /// layer mask is what the window server traces for the shadow, and a
    /// SwiftUI stroke drawn on its own shape drifts off that outline at the
    /// corners, leaving a broken double edge.
    @MainActor
    static func shapePanelWindow(_ contentView: NSView, radius: CGFloat) {
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        let edge = PanelEdgeView(radius: radius)
        edge.frame = contentView.bounds
        contentView.addSubview(edge)
    }
}

/// The panel's 0.5pt edge, on the same rounded shape as the window mask.
/// A layer border takes a CGColor, which is resolved once, so the edge lives
/// in its own view that recolors itself when the appearance changes.
final class PanelEdgeView: NSView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = Theme.nsPanelEdge.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Clicks go to the content underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Glass behind an AppKit window, switching material with the appearance
/// the same way the SwiftUI panels do.
final class PanelEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMaterial()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }

    private func updateMaterial() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        material = Theme.panelMaterial(for: isDark ? .dark : .light)
    }
}

extension View {
    /// Glass background shared by the search panel and the action panel.
    /// The outline comes from `Theme.shapePanelWindow`; the window draws
    /// the shadow.
    func panelChrome() -> some View {
        background { PanelBackground() }
    }

    /// Hides whatever scrolls into a list's top and bottom margins, where the
    /// edge of the row above or below would otherwise peek out.
    func clipToListMargins() -> some View {
        mask {
            Rectangle().padding(.vertical, Theme.rowInset - Theme.rowSpacing / 2)
        }
    }

    /// Tinted rounded pane that sets a preview apart from the list beside it,
    /// in place of a full-height dividing line.
    func paneBackground() -> some View {
        background {
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(Theme.paneFill)
        }
        .padding([.top, .bottom, .trailing], Theme.rowInset)
    }

    /// Rounded bar floating inside the bottom of a panel, for footers. It
    /// sits at the same inset and radius as the rows above, so its corners
    /// run parallel to the panel's. Only the shape is inset: the footer's
    /// content keeps its own padding.
    func barBackground(
        inset: CGFloat = Theme.rowInset,
        radius: CGFloat = Theme.rowRadius
    ) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.barFill)
                .padding(.horizontal, inset)
        }
        .padding(.bottom, inset)
    }
}

/// A single key drawn like a physical keycap: lit from above, with a
/// one-point ledge underneath.
struct Keycap: View {
    let key: String
    var fontSize: CGFloat = 10
    @Environment(\.colorScheme) private var colorScheme

    private var height: CGFloat { fontSize + 8 }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
    }

    var body: some View {
        Text(key)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, fontSize * 0.45)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background {
                shape
                    .fill(LinearGradient(
                        colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.07)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.45 : 0.15),
                        radius: 0, x: 0, y: 1
                    )
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.16 : 0.7),
                            Color.primary.opacity(0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
    }
}
