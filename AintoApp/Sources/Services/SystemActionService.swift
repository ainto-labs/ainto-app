import AppKit
import Foundation

enum SystemAction: String, CaseIterable, Identifiable {
    case sleep
    case lockScreen = "lock-screen"
    case logOut = "log-out"
    case restart
    case shutDown = "shut-down"
    case emptyTrash = "empty-trash"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: "Sleep"
        case .lockScreen: "Lock Screen"
        case .logOut: "Log Out"
        case .restart: "Restart"
        case .shutDown: "Shut Down"
        case .emptyTrash: "Empty Trash"
        }
    }

    var icon: String {
        switch self {
        case .sleep: "moon.zzz"
        case .lockScreen: "lock.fill"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .restart: "restart"
        case .shutDown: "power"
        case .emptyTrash: "trash"
        }
    }

    var requiresConfirmation: Bool {
        switch self {
        case .logOut, .restart, .shutDown: true
        default: false
        }
    }
}

enum SystemActionError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message): message
        }
    }
}

enum SystemActionService {
    /// Executes only fixed operations selected from `SystemAction`.
    static func execute(_ action: SystemAction) throws {
        switch action {
        case .sleep:
            try run("/usr/bin/pmset", arguments: ["sleepnow"])
        case .lockScreen:
            try lockScreen()
        case .emptyTrash:
            try runAppleScript("tell application \"Finder\" to empty trash")
        case .logOut:
            try runAppleScript("tell application \"System Events\" to log out")
        case .restart:
            try runAppleScript("tell application \"System Events\" to restart")
        case .shutDown:
            try runAppleScript("tell application \"System Events\" to shut down")
        }
    }

    private static func lockScreen() throws {
        guard AXIsProcessTrusted() else {
            throw SystemActionError.unavailable("Enable Accessibility access for Ainto to lock the screen.")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x0C, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x0C, keyDown: false)
        else {
            throw SystemActionError.unavailable("The macOS lock screen shortcut is unavailable.")
        }
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func runAppleScript(_ fixedScript: String) throws {
        try run("/usr/bin/osascript", arguments: ["-e", fixedScript])
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw SystemActionError.unavailable("The macOS system helper is unavailable.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SystemActionError.failed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemActionError.failed(message.flatMap { $0.isEmpty ? nil : $0 } ?? "The system action failed.")
        }
    }
}
