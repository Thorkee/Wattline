// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Wattline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Wattline", targets: ["Wattline"])],
    targets: [
        .executableTarget(name: "Wattline"),
        .testTarget(name: "WattlineTests", dependencies: ["Wattline"])
    ]
)
