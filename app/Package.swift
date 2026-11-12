// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Daybreak",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DaybreakApp", targets: ["DaybreakApp"]),
    ],
    targets: [
        // Pure logic: engine process execution, JSON decoding, config preservation, whitelist matching.
        .target(name: "DaybreakKit"),
        // SwiftUI front end. Never reimplements update/quit/relaunch logic; it shells out to the Python engine.
        .executableTarget(name: "DaybreakApp", dependencies: ["DaybreakKit"]),
        .testTarget(name: "DaybreakKitTests", dependencies: ["DaybreakKit"]),
    ],
    swiftLanguageModes: [.v6]
)
