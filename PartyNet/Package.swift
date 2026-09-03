// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PartyNet",
    platforms: [.iOS(.v26), .tvOS(.v26), .macOS(.v26)],
    products: [
        .library(
            name: "PartyNet",
            targets: ["PartyNet"]
        ),
        .executable(
            name: "partyload",
            targets: ["partyload"]
        ),
        .library(
            name: "PartyNetTestSupport",
            targets: ["PartyNetTestSupport"]
        ),
        .executable(
            name: "partyfault",
            targets: ["partyfault"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies",
            exact: "1.10.0"
        ),
    ],
    targets: [
        .target(
            name: "PartyNet",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .executableTarget(
            name: "partyload",
            dependencies: ["PartyNet"]
        ),
        .target(
            name: "PartyNetTestSupport",
            dependencies: [
                "PartyNet",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .executableTarget(
            name: "partyfault",
            dependencies: ["PartyNet", "PartyNetTestSupport"]
        ),
        .testTarget(
            name: "PartyNetTests",
            dependencies: [
                "PartyNet",
                "PartyNetTestSupport",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ]
        ),
    ]
)
