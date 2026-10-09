// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "SwiftSocket",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(name: "SwiftSocket", targets: ["SwiftSocket"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "SwiftSocket",
            dependencies: ["SwiftSocketC"]
        ),
        .target(
            name: "SwiftSocketC"
        )
    ]
)
