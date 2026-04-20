// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "photo-snail",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PhotoSnailCore", targets: ["PhotoSnailCore"]),
        .library(name: "PhotoSnailPhotos", targets: ["PhotoSnailPhotos"]),
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
        // PhotoKit + AppleScript surface shared by `photo-snail-app` and
        // `photo-snail-gui`. Kept out of `PhotoSnailCore` so the file-path
        // CLI doesn't have to link `Photos.framework`.
        .target(
            name: "PhotoSnailPhotos",
            dependencies: ["PhotoSnailCore"],
            path: "Sources/PhotoSnailPhotos",
            linkerSettings: [
                .linkedFramework("Photos"),
            ]
        ),
        .executableTarget(
            name: "photo-snail-cli",
            dependencies: ["PhotoSnailCore"],
            path: "Sources/photo-snail-cli"
        ),
        .executableTarget(
            name: "photo-snail-app",
            dependencies: ["PhotoSnailCore", "PhotoSnailPhotos"],
            path: "Sources/PhotoSnailApp",
            exclude: ["Info.plist"],
            linkerSettings: [
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
            dependencies: ["PhotoSnailCore", "PhotoSnailPhotos"],
            path: "Sources/PhotoSnailGUI",
            exclude: ["Info.plist"],
            linkerSettings: [
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
