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
        .library(name: "PartyBoxCore", targets: ["PartyBoxCore"]),
        .library(name: "PartyGameRuntime", targets: ["PartyGameRuntime"]),
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
            dependencies: ["PartyNet", "PartyNetTestSupport"]
        ),
        .target(
            name: "PartyNetTestSupport",
            dependencies: [
                "PartyNet",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .target(name: "PartyBoxCore", dependencies: ["PartyNet"]),
        .target(name: "PartyGameRuntime", dependencies: ["PartyNet", "PartyBoxCore"]),
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
        .testTarget(
            name: "PartyBoxCoreTests",
            dependencies: ["PartyBoxCore", "PartyNet"]
        ),
    ]
)
