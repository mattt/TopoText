// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "TopoText",
    platforms: [
        .macOS("15.1")
    ],
    products: [
        .library(
            name: "TopoText",
            targets: ["TopoText"]
        )
    ],
    targets: [
        .target(
            name: "TopoText",
            dependencies: []
        )
    ]
)
