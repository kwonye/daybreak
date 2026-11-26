// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Evergreen",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EvergreenApp", targets: ["EvergreenApp"]),
        .executable(name: "evergreen", targets: ["EvergreenCLI"]),
        .executable(name: "evergreen-store-installer", targets: ["EvergreenStoreInstaller"]),
    ],
    targets: [
        // Native engine and shared config and report models.
        .target(name: "EvergreenStoreBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Security")]),
        .target(name: "EvergreenKit", dependencies: ["EvergreenStoreBridge"]),
        .executableTarget(name: "EvergreenCLI", dependencies: ["EvergreenKit"]),
        .executableTarget(name: "EvergreenApp", dependencies: ["EvergreenKit"]),
        .executableTarget(name: "EvergreenStoreInstaller", dependencies: ["EvergreenKit"]),
        .testTarget(name: "EvergreenKitTests", dependencies: ["EvergreenKit"]),
    ],
    swiftLanguageModes: [.v6]
)
