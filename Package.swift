// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TrafficCtrl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "traffic-ctrl", targets: ["TrafficCtrl"]),
        .executable(name: "trctrl", targets: ["Trctrl"])
    ],
    targets: [
        .executableTarget(name: "TrafficCtrl", path: "Sources/TrafficCtrl"),
        .executableTarget(name: "Trctrl", path: "Sources/trctrl")
    ]
)
