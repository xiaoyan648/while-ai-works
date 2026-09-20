// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhileAIWorks",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WhileAIWorks", targets: ["WhileAIWorks"])],
    targets: [
        .target(name: "WhileCore"),
        .executableTarget(name: "WhileAIWorks", dependencies: ["WhileCore"],
                          resources: [.copy("Resources/FishAssets"), .copy("Resources/AquariumAssets")]),
        .executableTarget(name: "CoreChecks", dependencies: ["WhileCore"], path: "Tests/WhileCoreTests")
    ]
)
