// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BucketBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BucketBrowser", targets: ["BucketBrowser"]),
        .library(name: "S3Kit", targets: ["S3Kit"]),
    ],
    targets: [
        .target(name: "S3Kit"),
        .executableTarget(
            name: "BucketBrowser",
            dependencies: ["S3Kit"]
        ),
        .testTarget(name: "S3KitTests", dependencies: ["S3Kit"]),
    ]
)
