// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TrafficCtrl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TrafficCtrlFilterProtocol", targets: ["TrafficCtrlFilterProtocol"]),
        .library(name: "TrafficCtrlFilterHostCore", targets: ["TrafficCtrlFilterHostCore"]),
        .executable(name: "traffic-ctrl", targets: ["TrafficCtrl"]),
        .executable(name: "trctrl", targets: ["Trctrl"])
    ],
    targets: [
        .target(name: "TrafficCtrlFilterProtocol", path: "Sources/TrafficCtrlFilterProtocol"),
        .target(
            name: "TrafficCtrlFilterEngine",
            dependencies: ["TrafficCtrlFilterProtocol"],
            path: "macOS/FilterExtension",
            exclude: ["Info.plist", "FilterExtension.entitlements", "main.swift"]
        ),
        .target(
            name: "TrafficCtrlFilterHostCore",
            dependencies: ["TrafficCtrlFilterProtocol"],
            path: "macOS/FilterHostCore"
        ),
        .executableTarget(
            name: "TrafficCtrlFilterHost",
            dependencies: ["TrafficCtrlFilterHostCore", "TrafficCtrlFilterProtocol"],
            path: "macOS/FilterHost",
            exclude: ["Info.plist", "FilterHost.entitlements"]
        ),
        .executableTarget(
            name: "TrafficCtrl",
            dependencies: ["TrafficCtrlFilterProtocol"],
            path: "Sources/TrafficCtrl"
        ),
        .executableTarget(name: "Trctrl", path: "Sources/trctrl")
    ]
)
