// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpWho",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "op-who",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
