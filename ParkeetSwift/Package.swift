// swift-tools-version: 5.9

import PackageDescription

let sherpaLibPath = "../sherpa-onnx/build-swift-macos/install/lib"
let sherpaIncludePath = "../sherpa-onnx/build-swift-macos/install/include"

let package = Package(
    name: "Parkeet",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            cSettings: [
                .headerSearchPath("include"),
            ]
        ),
        .executableTarget(
            name: "Parkeet",
            dependencies: ["CSherpaOnnx"],
            swiftSettings: [
                .unsafeFlags([
                    "-I\(sherpaIncludePath)",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(sherpaLibPath)",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(sherpaLibPath)",
                ]),
                .linkedLibrary("sherpa-onnx-c-api"),
                .linkedLibrary("onnxruntime"),
            ]
        ),
    ]
)
