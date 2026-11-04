// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OctokanSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "OctokanSDK", targets: ["OctokanSDK"]),
    ],
    targets: [
        .target(name: "OctokanSDK"),
        .testTarget(name: "OctokanSDKTests", dependencies: ["OctokanSDK"]),
    ]
)
