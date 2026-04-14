import AppKit
import Carbon
import AintoCore

/// Global text expansion service.
/// Monitors all keystrokes via CGEvent tap, matches snippet keywords using a Trie,
/// and replaces them with expanded text.
///
/// Reference: GenSnippets (https://github.com/jaynguyen-vn/gen-snippets)
///
/// Requires:
/// - System Settings → Privacy & Security → Accessibility
/// - System Settings → Privacy & Security → Input Monitoring
@MainActor
final class TextExpander {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Lock protecting all static mutable state accessed from CGEvent tap thread.
    private static let lock = NSLock()

    /// Rolling buffer of recent keystrokes for matching.
    private static var buffer = ""
    private static let maxBufferLength = 50
    private static var lastKeystrokeTime = Date()
    private static let bufferTimeout: TimeInterval = 10 // clear after 10s inactivity

    /// Snippet keyword → expansion mapping.
    private static var snippetMap: [String: String] = [:]

    /// Trie for efficient keyword matching.
    private static var trie = Trie()

    // MARK: - Public

    func start() {
        guard checkAccessibilityPermission() else {
            print("TextExpander: Accessibility permission not granted")
            requestAccessibilityPermission()
            return
        }

        loadSnippets()
        installEventTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Reload snippets from disk (call after snippet CRUD).
    func reloadSnippets() {
        loadSnippets()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Snippets

    private func loadSnippets() {
        guard let cStr = rc_snippets_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        Self.lock.lock()
        Self.snippetMap.removeAll()
        Self.trie = Trie()

        for entry in entries {
            guard let keyword = entry["keyword"] as? String, !keyword.isEmpty,
                  let expansion = entry["expansion"] as? String else { continue }
            Self.snippetMap[keyword] = expansion
            Self.trie.insert(keyword)
        }
        Self.lock.unlock()
    }

    // MARK: - CGEvent Tap

    private func installEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // The callback must be a C function pointer — use a static method
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: TextExpander.eventCallback,
            userInfo: nil
        )

        guard let tap else {
            print("TextExpander: Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        Self.sharedEventTap = tap
    }

    /// C-compatible callback for CGEvent tap.
    /// Stored tap reference for re-enabling on timeout.
    private static var sharedEventTap: CFMachPort?

    private static let eventCallback: CGEventTapCallBack = { _, type, event, _ in
        // Re-enable tap if it gets disabled (system does this after timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = sharedEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        // Skip keystroke capture for password managers and secure input fields
        if SecureInput.isActive {
            return Unmanaged.passRetained(event)
        }

        // Skip if modifier keys are held (Cmd, Ctrl, Alt)
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            lock.lock()
            buffer = ""
            lock.unlock()
            return Unmanaged.passRetained(event)
        }

        // Get the character
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)

        guard length > 0 else {
            return Unmanaged.passRetained(event)
        }

        let char = String(utf16CodeUnits: chars, count: length)

        lock.lock()

        // Check for buffer timeout
        let now = Date()
        if now.timeIntervalSince(lastKeystrokeTime) > bufferTimeout {
            buffer = ""
        }
        lastKeystrokeTime = now

        // Handle backspace
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 { // Backspace
            if !buffer.isEmpty {
                buffer.removeLast()
            }
            lock.unlock()
            return Unmanaged.passRetained(event)
        }

        // Append to buffer
        buffer += char
        if buffer.count > maxBufferLength {
            buffer = String(buffer.suffix(maxBufferLength))
        }

        // Check if buffer ends with any snippet keyword
        if let (keyword, expansion) = findMatch() {
            // Remove the keyword from the buffer
            buffer = String(buffer.dropLast(keyword.count))
            lock.unlock()

            // Perform replacement on main thread
            DispatchQueue.main.async {
                performReplacement(keywordLength: keyword.count, expansion: expansion)
            }

            // Suppress the last keystroke (it's part of the keyword)
            return nil
        }

        lock.unlock()
        return Unmanaged.passRetained(event)
    }

    /// Check if the buffer ends with any snippet keyword.
    private static func findMatch() -> (keyword: String, expansion: String)? {
        // Check from longest possible match to shortest
        let maxLen = min(buffer.count, maxBufferLength)
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = String(buffer.suffix(len))
            if trie.contains(suffix), let expansion = snippetMap[suffix] {
                // Resolve placeholders
                var resolved = expansion
                if let cStr = rc_snippet_expand(expansion, nil) {
                    resolved = String(cString: cStr)
                    rc_free_string(cStr)
                }
                return (suffix, resolved)
            }
        }
        return nil
    }

    /// Delete the keyword characters and type the expansion.
    private static func performReplacement(keywordLength: Int, expansion: String) {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Step 1: Send backspace to delete the keyword (minus the last char which was suppressed)
        for _ in 0..<(keywordLength - 1) {
            let backDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
            backDown?.post(tap: .cghidEventTap)
            let backUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            backUp?.post(tap: .cghidEventTap)
        }

        // Step 2: Small delay to let backspaces process
        usleep(10_000) // 10ms

        // Step 3: Type the expansion by writing to clipboard and pasting
        // Mark as transient so ClipboardMonitor ignores it
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(expansion, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        // Simulate Cmd+V
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Step 4: Restore previous clipboard after a delay
        if let old = oldContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }
}

// MARK: - Trie

/// Simple Trie for efficient keyword exact matching.
final class Trie {
    private let root = TrieNode()

    func insert(_ word: String) {
        var node = root
        for char in word {
            if node.children[char] == nil {
                node.children[char] = TrieNode()
            }
            guard let next = node.children[char] else { return }
            node = next
        }
        node.isEnd = true
    }

    func contains(_ word: String) -> Bool {
        var node = root
        for char in word {
            guard let next = node.children[char] else { return false }
            node = next
        }
        return node.isEnd
    }
}

/// Detects when macOS secure event input is active (password fields, etc.).
/// Uses Carbon's IsSecureEventInputEnabled() — returns true when any app
/// has enabled secure input (e.g., 1Password, Safari password fields).
enum SecureInput {
    static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}

private final class TrieNode {
    var children: [Character: TrieNode] = [:]
    var isEnd = false
}
