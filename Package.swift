// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "photo-snail",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhotoSnailCore", targets: ["PhotoSnailCore"]),
        .executable(name: "photo-snail-cli", targets: ["photo-snail-cli"]),
        .executable(name: "photo-snail-app", targets: ["photo-snail-app"]),
        .executable(name: "photo-snail-gui", targets: ["photo-snail-gui"]),
    ],
    targets: [
        .target(
            name: "PhotoSnailCore",
            path: "Sources/PhotoSnailCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "photo-snail-cli",
            dependencies: ["PhotoSnailCore"],
            path: "Sources/photo-snail-cli"
        ),
        .executableTarget(
            name: "photo-snail-app",
            dependencies: ["PhotoSnailCore"],
            path: "Sources/PhotoSnailApp",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("Photos"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhotoSnailApp/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "photo-snail-gui",
            dependencies: ["PhotoSnailCore"],
            path: "Sources/PhotoSnailGUI",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("Photos"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhotoSnailGUI/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "PhotoSnailCoreTests",
            dependencies: ["PhotoSnailCore"],
            path: "Tests/PhotoSnailCoreTests"
        ),
    ]
)
