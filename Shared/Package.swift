// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "DropsiftShared",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11),
    ],
    products: [
        .library(name: "DropsiftShared", targets: ["DropsiftShared"]),
    ],
    targets: [
        .target(
            name: "DropsiftShared",
            path: "DropsiftShared"
        ),
        .testTarget(
            name: "DropsiftSharedTests",
            dependencies: ["DropsiftShared"],
            path: "DropsiftSharedTests"
        ),
    ]
)
