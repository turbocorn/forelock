// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chelka",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Chelka", targets: ["Chelka"])],
    targets: [
        .target(name: "ChelkaCore"),
        .executableTarget(name: "Chelka", dependencies: ["ChelkaCore"]),
        .testTarget(name: "ChelkaCoreTests", dependencies: ["ChelkaCore", "Chelka"])
    ],
    swiftLanguageModes: [.v5]
)
