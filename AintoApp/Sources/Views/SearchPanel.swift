import AppKit
import SwiftUI

/// Non-activating floating panel for the search interface.
/// Uses NSPanel + .nonactivatingPanel so the previously focused app keeps focus.
/// This allows "paste to frontmost app" to work after selecting a clipboard item.
@MainActor
final class SearchPanel: NSPanel {
    private let hostingView: NSHostingView<MainView>
    let viewModel = SearchViewModel()

    /// The app that was frontmost before we showed the panel.
    private var previousApp: NSRunningApplication?

    /// Floating action panel window.
    private var actionWindow: NSWindow?
    private var actionSelectedIndex = 0

    init() {
        let mainView = MainView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: mainView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        self.contentView = hostingView
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        // Accept keyboard input even without activating the app
        self.becomesKeyOnlyIfNeeded = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        if let contentView = self.contentView {
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        // Wire up the paste action
        viewModel.onPasteAndHide = { [weak self] in
            self?.pasteToFrontmostApp()
        }

        // Wire up grab selection for AI commands
        viewModel.onGrabSelection = { [weak self] completion in
            self?.grabSelectionFromPreviousApp(completion: completion)
        }
    }

    /// Whether the user has ever positioned the panel manually.
    private var hasUserPosition = false

    func showPanel() {
        // Remember the currently focused app before showing
        previousApp = NSWorkspace.shared.frontmostApplication

        if !hasUserPosition {
            let screen = NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main ?? NSScreen.screens.first

            if let screen {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - frame.width / 2
                let y = screenFrame.maxY - (screenFrame.height * 0.25)
                setFrameOrigin(NSPoint(x: x, y: y))
            }
            hasUserPosition = true
        }

        // Do NOT call NSApp.activate — keep the previous app focused
        makeKeyAndOrderFront(nil)
        viewModel.selectAll()
    }

    func hidePanel() {
        hideActionPanel()
        orderOut(nil)
    }

    /// Hide panel, re-activate the previous app, and simulate Cmd+V to paste.
    func pasteToFrontmostApp() {
        hidePanel()

        // Re-activate the previous app
        if let app = previousApp {
            app.activate()
        }

        // Small delay to let the app activate, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
        }
    }

    /// Simulate Cmd+V keystroke.
    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Hide panel, activate previous app, simulate Cmd+C to grab selection, then call back.
    func grabSelectionFromPreviousApp(completion: @escaping (String) -> Void) {
        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)

        // Hide panel and activate previous app
        hidePanel()
        if let app = previousApp {
            app.activate()
        }

        // Wait for app activation, then simulate Cmd+C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            self.simulateCopy()

            // Wait for clipboard to update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let selection = pasteboard.string(forType: .string) ?? ""

                // Restore previous clipboard content
                pasteboard.clearContents()
                if let prev = previousContent {
                    pasteboard.setString(prev, forType: .string)
                    pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                }

                // Re-show panel and call back
                self.makeKeyAndOrderFront(nil)
                completion(selection)
            }
        }
    }

    /// Simulate Cmd+C keystroke.
    private func simulateCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        cDown?.flags = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        cUp?.flags = .maskCommand
        cUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Action Panel

    func showActionPanel() {
        let actions = viewModel.currentActions
        guard !actions.isEmpty else { return }
        actionSelectedIndex = 0

        let title = viewModel.results.indices.contains(viewModel.selectedIndex)
            ? viewModel.results[viewModel.selectedIndex].title : ""

        let panelView = ActionPanelView(
            title: title,
            actions: actions,
            onDismiss: { [weak self] in self?.hideActionPanel() },
            selectedIndex: actionSelectedIndex
        )
        let hosting = NSHostingView(rootView: panelView)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(actions.count * 32 + 70))

        let window = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating

        // Position to the right of the main panel
        let mainFrame = self.frame
        let x = mainFrame.maxX + 8
        let y = mainFrame.maxY - hosting.frame.height - 40
        window.setFrameOrigin(NSPoint(x: x, y: y))

        window.orderFront(nil)
        actionWindow = window
        viewModel.showActionPanel = true
    }

    func hideActionPanel() {
        actionWindow?.orderOut(nil)
        actionWindow = nil
        viewModel.showActionPanel = false
        actionSelectedIndex = 0
    }

    func updateActionPanelSelection() {
        guard let window = actionWindow else { return }
        let actions = viewModel.currentActions
        let title = viewModel.results.indices.contains(viewModel.selectedIndex)
            ? viewModel.results[viewModel.selectedIndex].title : ""

        let panelView = ActionPanelView(
            title: title,
            actions: actions,
            onDismiss: { [weak self] in self?.hideActionPanel() },
            selectedIndex: actionSelectedIndex
        )
        let hosting = NSHostingView(rootView: panelView)
        hosting.frame = window.contentView?.frame ?? .zero
        window.contentView = hosting
    }

    var isPanelVisible: Bool {
        isVisible && isKeyWindow
    }

    // Auto-hide when losing focus
    override func resignKey() {
        super.resignKey()
        hidePanel()
    }

    // NSPanel override: allow key events even when app is not active
    override var canBecomeKey: Bool { true }

    private var localEventMonitor: Any?

    private func installKeyMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = Int(event.keyCode)
            let hasCmd = flags.contains(.command)

            // Forward standard text editing shortcuts to first responder.
            // NonActivatingPanel doesn't receive Edit menu actions automatically.
            if hasCmd, self.firstResponder is NSTextView {
                let action: Selector? = switch keyCode {
                case 6: flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")) // Z
                case 0: #selector(NSText.selectAll(_:))  // A
                case 7: #selector(NSText.cut(_:))        // X
                default: nil
                }
                if let action {
                    NSApp.sendAction(action, to: nil, from: nil)
                    return nil
                }
            }

            // Cmd+K — toggle action panel
            if hasCmd && keyCode == 40 { // K key
                if self.viewModel.showActionPanel {
                    self.hideActionPanel()
                } else {
                    self.showActionPanel()
                }
                return nil
            }

            // When action panel is shown, handle its navigation
            if self.viewModel.showActionPanel {
                let actions = self.viewModel.currentActions
                switch keyCode {
                case 125: // Down
                    if self.actionSelectedIndex < actions.count - 1 {
                        self.actionSelectedIndex += 1
                        self.updateActionPanelSelection()
                    }
                    return nil
                case 126: // Up
                    if self.actionSelectedIndex > 0 {
                        self.actionSelectedIndex -= 1
                        self.updateActionPanelSelection()
                    }
                    return nil
                case 36: // Enter — run selected action
                    if self.actionSelectedIndex < actions.count {
                        let action = actions[self.actionSelectedIndex]
                        action.action()
                        self.hideActionPanel()
                        if !action.keepPanel {
                            self.hidePanel()
                        }
                    }
                    return nil
                case 53: // Escape — close action panel
                    self.hideActionPanel()
                    return nil
                default:
                    return event
                }
            }

            // Cmd+Enter — save snippet/AI command form
            if hasCmd && keyCode == 36 {
                if self.viewModel.isEditingSnippet {
                    self.viewModel.saveEditingSnippet()
                    return nil
                }
                if self.viewModel.isEditingAICommand {
                    self.viewModel.saveEditingAICommand()
                    return nil
                }
            }

            // Cmd+C in Claude page — copy last response
            if hasCmd && keyCode == 8 && self.viewModel.page == .claude { // C key
                self.viewModel.claudeCopyLastResponse()
                return nil
            }

            // Cmd+Enter in Claude page — replace selected text with response
            if hasCmd && keyCode == 36 && self.viewModel.page == .claude && !self.viewModel.claudeIsStreaming {
                self.viewModel.replaceSelectedText()
                return nil
            }

            // Cmd+N — new snippet/AI command
            if hasCmd && keyCode == 45 { // N key
                if self.viewModel.page == .snippets && !self.viewModel.isEditingSnippet {
                    self.viewModel.addSnippet()
                    return nil
                }
                if self.viewModel.page == .aiCommands && !self.viewModel.isEditingAICommand {
                    self.viewModel.addAICommand()
                    return nil
                }
            }

            // Cmd+D or Cmd+Backspace — delete selected item
            if hasCmd && (keyCode == 2 || keyCode == 51) { // D key or Backspace
                if self.viewModel.page == .snippets && !self.viewModel.isEditingSnippet {
                    let items = self.viewModel.filteredSnippets
                    if self.viewModel.snippetSelectedIndex < items.count {
                        self.viewModel.deleteSnippet(id: items[self.viewModel.snippetSelectedIndex].id)
                    }
                    return nil
                }
                if self.viewModel.page == .aiCommands && !self.viewModel.isEditingAICommand {
                    let items = self.viewModel.filteredAICommands
                    if self.viewModel.aiCommandSelectedIndex < items.count {
                        self.viewModel.deleteAICommand(id: items[self.viewModel.aiCommandSelectedIndex].id)
                    }
                    return nil
                }
                if self.viewModel.page == .clipboard {
                    let items = self.viewModel.filteredClipboardItems
                    if self.viewModel.clipboardSelectedIndex < items.count {
                        self.viewModel.deleteClipboardItem(id: items[self.viewModel.clipboardSelectedIndex].id)
                    }
                    return nil
                }
            }

            // Cmd+E — edit selected snippet/AI command
            if hasCmd && keyCode == 14 { // E key
                if self.viewModel.page == .snippets && !self.viewModel.isEditingSnippet {
                    self.viewModel.editSelectedSnippet()
                    return nil
                }
                if self.viewModel.page == .aiCommands && !self.viewModel.isEditingAICommand {
                    self.viewModel.editSelectedAICommand()
                    return nil
                }
            }

            // Tab — toggle search mode (apps ↔ Claude)
            if keyCode == 48 && !hasCmd && self.viewModel.page == .main { // Tab key
                self.viewModel.toggleSearchMode()
                return nil
            }

            switch keyCode {
            case 53 where self.viewModel.isEditingSnippet: // Escape in snippet edit — cancel
                self.viewModel.cancelEditingSnippet()
                return nil
            case 53 where self.viewModel.isEditingAICommand: // Escape in AI command edit — cancel
                self.viewModel.cancelEditingAICommand()
                return nil
            case 125: // Down arrow
                self.viewModel.moveSelection(by: 1)
                return nil
            case 126: // Up arrow
                self.viewModel.moveSelection(by: -1)
                return nil
            case 36: // Enter/Return
                if self.viewModel.searchMode == .claude && self.viewModel.page == .main {
                    self.viewModel.claudeAsk()
                    return nil
                }
                if self.viewModel.page == .claude && !self.viewModel.claudeIsStreaming {
                    self.viewModel.claudeAsk()
                    return nil
                }
                self.viewModel.openSelected()
                if self.viewModel.page == .main {
                    self.hidePanel()
                }
                return nil
            case 53: // Escape
                if self.viewModel.page != .main {
                    self.viewModel.goBack()
                } else if self.viewModel.query.isEmpty {
                    self.hidePanel()
                } else {
                    self.viewModel.clearQuery()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        installKeyMonitor()
    }

    override func orderOut(_ sender: Any?) {
        removeKeyMonitor()
        super.orderOut(sender)
    }
}
