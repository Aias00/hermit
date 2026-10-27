// swift-tools-version:5.9
import PackageDescription

// Library-only snapshot of Cluas/SwiftTerm at dd7f2cd; see UPSTREAM.json.
let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v13), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm",
        exclude: ["Mac/README.md"], resources: [.process("Apple/Metal/Shaders.metal")])],
    swiftLanguageVersions: [.v5]
)
