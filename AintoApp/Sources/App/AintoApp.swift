import Cocoa

// Traditional AppKit lifecycle for menu bar apps.
// NSApp.delegate is directly our AppDelegate — no SwiftUI wrapper.
@main
struct AintoApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
