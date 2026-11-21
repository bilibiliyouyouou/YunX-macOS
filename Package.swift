// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "YunXMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "YunXMac", targets: ["YunXMac"])
    ],
    targets: [
        .executableTarget(name: "YunXMac")
    ],
    swiftLanguageModes: [.v5]
)
