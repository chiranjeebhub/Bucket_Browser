// swift-tools-version:5.10
import PackageDescription

// The direct-download build (BUCKET_BROWSER_DIRECT=1, see scripts/build-app.sh) updates itself
// with Sparkle. The Mac App Store build leaves Sparkle out entirely.
let direct = Context.environment["BUCKET_BROWSER_DIRECT"] == "1"

let package = Package(
    name: "BucketBrowser",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BucketBrowser", targets: ["BucketBrowser"]),
        .library(name: "S3Kit", targets: ["S3Kit"]),
    ],
    dependencies: direct
        ? [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")]
        : [],
    targets: [
        .target(name: "S3Kit"),
        .executableTarget(
            name: "BucketBrowser",
            dependencies: ["S3Kit"] + (direct ? [.product(name: "Sparkle", package: "Sparkle")] : []),
            swiftSettings: direct ? [.define("SPARKLE")] : []
        ),
        .testTarget(name: "S3KitTests", dependencies: ["S3Kit"]),
    ]
)
