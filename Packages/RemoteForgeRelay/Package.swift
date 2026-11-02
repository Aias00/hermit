// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RemoteForgeRelay",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RemoteForgeRelay", targets: ["RemoteForgeRelay"]),
        .library(name: "RemoteForgeRelayNIO", targets: ["RemoteForgeRelayNIO"]),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")],
    targets: [
        .target(name: "RemoteForgeRelay"),
        .target(name: "RemoteForgeRelayNIO", dependencies: [
            "RemoteForgeRelay",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
    ]
)
