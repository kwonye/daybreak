// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daybreak",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DaybreakApp", targets: ["DaybreakApp"]),
        .executable(name: "daybreak", targets: ["DaybreakCLI"]),
        .executable(name: "daybreak-store-installer", targets: ["DaybreakStoreInstaller"]),
    ],
    targets: [
        // Native engine and shared config and report models.
        .target(name: "DaybreakStoreBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Security")]),
        .target(name: "DaybreakKit", dependencies: ["DaybreakStoreBridge"]),
        .executableTarget(name: "DaybreakCLI", dependencies: ["DaybreakKit"]),
        .executableTarget(name: "DaybreakApp", dependencies: ["DaybreakKit"]),
        .executableTarget(name: "DaybreakStoreInstaller", dependencies: ["DaybreakKit"]),
        .testTarget(name: "DaybreakKitTests", dependencies: ["DaybreakKit"]),
    ],
    swiftLanguageModes: [.v6]
)
