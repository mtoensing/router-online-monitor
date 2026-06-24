// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FritzBoxBandwidth",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FritzBoxBandwidthMenuBar", targets: ["FritzBoxBandwidthMenuBar"])
    ],
    targets: [
        .executableTarget(name: "FritzBoxBandwidthMenuBar")
    ]
)
