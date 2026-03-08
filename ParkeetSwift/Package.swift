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
                ]),
                .linkedLibrary("sherpa-onnx-c-api"),
                .linkedLibrary("sherpa-onnx-core"),
                .linkedLibrary("onnxruntime"),
                .linkedLibrary("kaldi-decoder-core"),
                .linkedLibrary("kaldi-native-fbank-core"),
                .linkedLibrary("sherpa-onnx-kaldifst-core"),
                .linkedLibrary("sherpa-onnx-fst"),
                .linkedLibrary("sherpa-onnx-fstfar"),
                .linkedLibrary("ssentencepiece_core"),
                .linkedLibrary("espeak-ng"),
                .linkedLibrary("piper_phonemize"),
                .linkedLibrary("ucd"),
                .linkedLibrary("kissfft-float"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
