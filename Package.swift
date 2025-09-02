// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SocketNativo",
    defaultLocalization: "es",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v16), .watchOS(.v10)],
    products: [
        .library(name: "SocketNativo", targets: ["SocketNativo"])
    ],
    targets: [
        .target(name: "SocketNativo", path: "Sources/SocketNativo"),

    ]
)
