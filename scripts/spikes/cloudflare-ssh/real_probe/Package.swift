// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RealCloudflareProbe",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "cloudflare-real-probe", targets: ["RealCloudflareProbe"])],
    dependencies: [
        .package(path: "../../../../Packages/CloudflareSSH"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")
    ],
    targets: [
        .executableTarget(name: "RealCloudflareProbe", dependencies: [
            .product(name: "CloudflareSSH", package: "CloudflareSSH"),
            .product(name: "CloudflareAccess", package: "CloudflareSSH"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ])
    ],
    swiftLanguageModes: [.v5]
)
