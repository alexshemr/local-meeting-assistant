// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalMeetingAssistant",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.13.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        // Эхоподавление LocalVQE (Apache-2.0): готовая статическая библиотека с C API.
        // Версия привязана к модели из scripts/fetch-localvqe-model.sh.
        .binaryTarget(
            name: "CLocalVQE",
            url: "https://github.com/pasrom/localvqe-xcframework/releases/download/1.0.3/LocalVQE.xcframework.zip",
            checksum: "15a7503e7d764012ee955ba04cef78a0b24f8d51856fc85b96d9be49d38624ba"
        ),
        .executableTarget(
            name: "LocalMeetingAssistant",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CLocalVQE",
            ],
            path: "Sources/LocalMeetingAssistant",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]
        ),
    ]
)
