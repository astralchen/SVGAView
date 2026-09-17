// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "SVGAView",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "SVGAView",
            targets: ["SVGAView"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
    ],
    targets: [
        .target(
            name: "SVGAView",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/SVGAView",
            linkerSettings: [
                .linkedLibrary("z")
            ],
            plugins: [
                .plugin(name: "SwiftProtobufPlugin", package: "swift-protobuf")
            ]
        ),
        .testTarget(
            name: "SVGAViewTests",
            dependencies: ["SVGAView"],
            path: "Tests/SVGAViewTests",
            resources: [
                .copy("Resources/banner.svga"),
                .copy("Resources/bubble.svga")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
