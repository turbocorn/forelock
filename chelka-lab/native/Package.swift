// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forelock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Forelock", targets: ["Chelka"]), .executable(name: "ForelockNativeHost", targets: ["ForelockNativeHost"])],
    targets: [
        .target(name: "ChelkaCore"),
        .target(name: "ForelockMusic"),
        .executableTarget(name: "ForelockNativeHost", dependencies: ["ForelockMusic"]),
        .executableTarget(name: "Chelka", dependencies: ["ChelkaCore", "ForelockMusic"]),
        .testTarget(name: "ChelkaCoreTests", dependencies: ["ChelkaCore", "Chelka", "ForelockMusic"])
    ],
    swiftLanguageModes: [.v5]
)
