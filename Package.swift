// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "AIUsage", targets: ["AIUsage"]),
        .executable(name: "claude-quota-capture", targets: ["ClaudeQuotaCapture"]),
    ],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "AIUsage", dependencies: ["QuotaCore"]),
        .executableTarget(name: "ClaudeQuotaCapture", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage", "QuotaCore"]),
    ]
)
