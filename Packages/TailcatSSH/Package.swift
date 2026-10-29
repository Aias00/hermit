// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TailcatSSH",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TailcatSSH", targets: ["TailcatSSH"]),
        .library(name: "TailscaleSSH", targets: ["TailscaleSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")
    ],
    targets: [
        .binaryTarget(name: "CTailcat", path: "Artifacts/CTailcat.xcframework"),
        .target(name: "TailcatSSH", dependencies: [
            "CTailcat",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ], linkerSettings: [
            .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"),
            .linkedFramework("SystemConfiguration"),
            .linkedLibrary("resolv")
        ]),
        .target(name: "TailscaleSSH", dependencies: [
            "CTailcat", "TailcatSSH",
            .product(name: "NIOCore", package: "swift-nio")
        ], linkerSettings: [
            .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"),
            .linkedFramework("SystemConfiguration"),
            .linkedLibrary("resolv")
        ]),
        .testTarget(name: "TailcatSSHTests", dependencies: ["TailcatSSH"]),
        .testTarget(name: "TailscaleSSHTests", dependencies: [
            "TailscaleSSH", "TailcatSSH", "CTailcat",
            .product(name: "NIOPosix", package: "swift-nio")
        ])
    ],
    swiftLanguageModes: [.v5]
)
