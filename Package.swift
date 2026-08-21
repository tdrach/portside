// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CLibProc", path: "Sources/CLibProc"),
        .executableTarget(
            name: "Portside",
            dependencies: ["CLibProc"],
            path: "Sources/Portside"
        ),
        .testTarget(
            name: "PortsideTests",
            dependencies: ["Portside"],
            path: "Tests/PortsideTests"
        ),
    ]
)
