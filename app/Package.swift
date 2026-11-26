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
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),
        // Native engine and shared config and report models.
        .target(name: "EvergreenStoreBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Security")]),
        .target(name: "EvergreenArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "EvergreenKit", dependencies: ["EvergreenStoreBridge", "EvergreenArchive"]),
        .executableTarget(name: "EvergreenCLI", dependencies: ["EvergreenKit"]),
        .executableTarget(name: "EvergreenApp", dependencies: ["EvergreenKit", "Sparkle"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "EvergreenStoreInstaller", dependencies: ["EvergreenKit"]),
        .testTarget(name: "EvergreenKitTests", dependencies: ["EvergreenKit", "EvergreenArchive"]),
    ],
    swiftLanguageModes: [.v6]
)
