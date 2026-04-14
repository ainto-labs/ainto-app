import Foundation

/// Resolve the resource bundle: Bundle.module (SPM) or Bundle.main (Xcode).
enum ResourceBundle {
    static var current: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    /// Find a resource URL, checking both flat (Xcode) and subdirectory (SPM) layouts.
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        current.url(forResource: name, withExtension: ext)
            ?? current.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
}
