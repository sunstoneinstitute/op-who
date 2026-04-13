// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpWho",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "OpWhoLib",
            path: "Sources/OpWhoLib",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "op-who",
            dependencies: ["OpWhoLib"],
            path: "Sources/op-who"
        ),
        .testTarget(
            name: "OpWhoTests",
            dependencies: ["OpWhoLib"],
            path: "Tests"
        ),
    ]
)
