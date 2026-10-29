// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudflareSSH",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CloudflareSSH", targets: ["CloudflareSSH"]),
        .library(name: "CloudflareAccess", targets: ["CloudflareAccess"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.2"),
        .package(path: "../SwiftSodium")
    ],
    targets: [
        .target(name: "CloudflareSSH", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")
        ]),
        .target(name: "CloudflareAccess", dependencies: [
            .product(name: "Sodium", package: "SwiftSodium")
        ]),
        .testTarget(name: "CloudflareSSHTests", dependencies: [
            "CloudflareSSH",
            .product(name: "NIOEmbedded", package: "swift-nio")
        ]),
        .testTarget(name: "CloudflareAccessTests", dependencies: ["CloudflareAccess"])
    ],
    swiftLanguageModes: [.v5]
)
