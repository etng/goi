// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "goi",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MdictKit", targets: ["MdictKit"]),
        .executable(name: "goi-cli", targets: ["goi-cli"]),
    ],
    targets: [
        .target(name: "MdictKit"),
        .executableTarget(name: "goi-cli", dependencies: ["MdictKit"]),
        .testTarget(name: "MdictKitTests", dependencies: ["MdictKit"]),
    ]
)
