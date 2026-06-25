// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RouterOnlineMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RouterOnlineMonitorMenuBar", targets: ["RouterOnlineMonitorMenuBar"])
    ],
    targets: [
        .executableTarget(name: "RouterOnlineMonitorMenuBar")
    ]
)
