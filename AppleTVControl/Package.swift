// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleTVControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppleTVControl", targets: ["AppleTVControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
    ],
    targets: [
        .target(
            name: "AppleTVControl",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "BigInt", package: "BigInt"),
                "CDNSSD",
            ]
        ),
        // C bridge to the system dns_sd.h: NetService.resolve does not dispatch
        // callbacks on macOS 26, so use DNSServiceResolve instead (callbacks go
        // through a dispatch queue, no RunLoop dependency).
        .systemLibrary(name: "CDNSSD"),
        .executableTarget(
            name: "AppleTVControlTests",
            dependencies: ["AppleTVControl"]
        ),
    ]
)
