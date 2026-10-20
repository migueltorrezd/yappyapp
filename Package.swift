// swift-tools-version: 6.2

import PackageDescription
import Foundation

// Swift 6.3 Command Line Tools ships the test interop dylib outside SwiftPM's
// default search paths. Full Xcode toolchains do not need this compatibility
// path, so only add it when that CLT-specific file exists.
let commandLineToolsTestingLibraryPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let commandLineToolsTestLinkerSettings: [LinkerSetting] =
    FileManager.default.fileExists(
        atPath: "\(commandLineToolsTestingLibraryPath)/lib_TestingInterop.dylib"
    )
    ? [.unsafeFlags([
        "-L", commandLineToolsTestingLibraryPath,
        "-Xlinker", "-rpath", "-Xlinker", commandLineToolsTestingLibraryPath
    ])]
    : []

let package = Package(
    name: "YappYapp",
    // L10N (YA-42): English is the base; fr, es and nl ship as .lproj tables.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "YappYapp", targets: ["YappYapp"])
    ],
    dependencies: [
        // Pin to the 0.17 minor line from 0.17.7 (0.17.3 was the first release
        // that loads Parakeet Ultra, `AsrModelVersion.ultra`). FluidAudio is
        // pre-1.0, so each 0.x minor can break API; `upToNextMinor` closes the
        // drift window on a fresh resolve. Matches Package.resolved. `traits: []`
        // opts out of the bundled NeMo text-normalization binary, which only
        // FluidAudio's TTS and ITN use (tools 6.2 is needed for the opt-out).
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.17.7"),
            traits: []
        ),
        // Sparkle powers "Check for updates" + the opt-out auto-check. Binary
        // xcframework; package_app.sh embeds it into Contents/Frameworks and
        // signs it. The ONLY other network surface besides model downloads —
        // documented in the privacy docs and gated by the settings toggle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // Test-only dependency. The standalone package lets `swift test` run
        // with Command Line Tools, where Apple's XCTest module is unavailable.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.4.1")
    ],
    targets: [
        .executableTarget(
            name: "YappYapp",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded by package_app.sh; the binary
                // must know to look in the bundle's Frameworks directory.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "YappYappTests",
            dependencies: [
                "YappYapp",
                .product(name: "Testing", package: "swift-testing")
            ],
            linkerSettings: commandLineToolsTestLinkerSettings
        )
    ]
)
