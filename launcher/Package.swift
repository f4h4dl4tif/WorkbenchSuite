// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Workbench", path: "Sources/Workbench")
    ]
)
