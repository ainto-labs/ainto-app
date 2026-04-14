// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AintoApp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // C bridge to Rust static library
        .systemLibrary(
            name: "AintoCore",
            path: "AintoCoreBridge"
        ),
        // Main application
        .executableTarget(
            name: "AintoApp",
            dependencies: [
                "AintoCore",
                .product(name: "HotKey", package: "HotKey"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            resources: [
                .copy("../Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/../ainto-core/target/release",
                    "-lainto_core",
                ]),
                // System frameworks needed by Rust code
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)

// HotKey library for global hotkey registration
package.dependencies.append(
    .package(url: "https://github.com/soffes/HotKey", from: "0.2.1")
)

// Sparkle auto-update framework
package.dependencies.append(
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
)
