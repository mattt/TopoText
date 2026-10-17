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
        ),
        .testTarget(
            name: "TopoTextTests",
            dependencies: ["TopoText"]
        ),
        // A development tool that checks TopoText against a real Notes database.
        // It is not a product, so packages that depend on TopoText don't build it.
        .executableTarget(
            name: "Validate",
            dependencies: ["TopoText"],
            path: "Tools/Validate"
        ),
    ]
)
