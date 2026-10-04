// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SuiAssistant",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "SuiAssistant", targets: ["CodexQuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaBar",
            path: "Sources/CodexQuotaBar"
        ),
        .testTarget(
            name: "CodexQuotaBarTests",
            dependencies: ["CodexQuotaBar"]
        )
    ]
)
