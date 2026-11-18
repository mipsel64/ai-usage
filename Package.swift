// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "AIUsage", targets: ["AIUsage"]),
    ],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "AIUsage", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage", "QuotaCore"]),
    ]
)
