// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PartyFault",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PartyFault", targets: ["PartyFault"]),
        .executable(name: "partyfault", targets: ["partyfault"]),
    ],
    targets: [
        .target(name: "PartyFault"),
        .executableTarget(name: "partyfault", dependencies: ["PartyFault"], path: "Sources/PartyFaultCLI"),
        .testTarget(name: "PartyFaultTests", dependencies: ["PartyFault"]),
    ]
)
