// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhileAIWorks",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WhileAIWorks", targets: ["WhileAIWorks"])],
    dependencies: [.package(url: "https://github.com/rive-app/rive-ios", exact: "6.27.0")],
    targets: [
        .target(name: "WhileCore"),
        .executableTarget(name: "WhileAIWorks",
                          dependencies: ["WhileCore", .product(name: "RiveRuntime", package: "rive-ios")],
                          resources: [.copy("Resources/FishAssets"), .copy("Resources/AquariumAssets"), .copy("Resources/Rive"), .copy("Resources/Licenses")]),
        .executableTarget(name: "CoreChecks", dependencies: ["WhileCore"], path: "Tests/WhileCoreTests")
    ]
)
