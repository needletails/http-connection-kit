// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HTTPConnectionKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .macCatalyst(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "HTTPConnectionKit",
            targets: ["HTTPConnectionKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.22.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/needletails/swift-nio-quic.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio-http3.git", from: "0.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.3"),
        .package(url: "https://github.com/mihai8804858/swift-gzip.git", from: "1.2.1")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HTTPConnectionKit",
            dependencies: ["HTTPConnection"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .target(
            name: "HTTPConnection",
            dependencies: [
                .product(name: "SwiftGzip", package: "swift-gzip"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "NIOHTTPCompression", package: "swift-nio-extras"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOHTTP3", package: "swift-nio-http3"),
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
        .testTarget(
            name: "HTTPConnectionKitTests",
            dependencies: [
                "HTTPConnection",
                "HTTPConnectionKit",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
                .product(name: "NIOHTTP3", package: "swift-nio-http3"),
                .product(name: "NIOQUIC", package: "swift-nio-quic"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ]
        ),
    ]
)
