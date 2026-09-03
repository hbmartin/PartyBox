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
    ],
    targets: [
        .target(
            name: "PartyNet"
        ),
        .executableTarget(
            name: "partyload",
            dependencies: ["PartyNet"]
        ),
        .testTarget(
            name: "PartyNetTests",
            dependencies: ["PartyNet"]
        ),
    ]
)
