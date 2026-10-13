// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DroidMirror",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DroidMirror", targets: ["DroidMirror"])],
    targets: [.executableTarget(name: "DroidMirror")]
)
