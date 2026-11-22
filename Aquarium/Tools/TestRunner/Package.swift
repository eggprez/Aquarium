// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AquariumTestRunner",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "AquariumTestRunner", path: "Sources")]
)
