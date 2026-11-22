// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daybreak",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DaybreakApp", targets: ["DaybreakApp"]),
        .executable(name: "daybreak", targets: ["DaybreakCLI"]),
    ],
    targets: [
        // Native engine and shared config and report models.
        .target(name: "DaybreakKit"),
        .executableTarget(name: "DaybreakCLI", dependencies: ["DaybreakKit"]),
        .executableTarget(name: "DaybreakApp", dependencies: ["DaybreakKit"]),
        .testTarget(name: "DaybreakKitTests", dependencies: ["DaybreakKit"]),
    ],
    swiftLanguageModes: [.v6]
)
