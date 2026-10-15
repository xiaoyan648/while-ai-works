// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhileAIWorks",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WhileAIWorks", targets: ["WhileAIWorks"])],
    dependencies: [.package(url: "https://github.com/rive-app/rive-ios", exact: "6.27.0"),
                   .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "WhileCore"),
        .target(name: "AgentHUDSupport", path: "Vendor/AgentHUDOpen/Sources/AgentHUDSupport",
                swiftSettings: [.unsafeFlags(["-swift-version", "6"])]),
        .target(name: "AgentHUDCore", dependencies: ["AgentHUDSupport"], path: "Vendor/AgentHUDOpen/Sources/AgentHUDCore",
                swiftSettings: [.unsafeFlags(["-swift-version", "6"])]),
        .executableTarget(name: "WhileAIWorks",
                          dependencies: ["WhileCore", "AgentHUDCore", "AgentHUDSupport", .product(name: "RiveRuntime", package: "rive-ios"),
                                         .product(name: "Sparkle", package: "Sparkle")],
                          resources: [.copy("Resources/FishAssets"), .copy("Resources/AquariumAssets"), .copy("Resources/Rive"), .copy("Resources/AgentMarks"), .copy("Resources/Licenses")]),
        .executableTarget(name: "CoreChecks", dependencies: ["WhileCore"], path: "Tests/WhileCoreTests")
    ]
)
