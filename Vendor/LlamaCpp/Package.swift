// swift-tools-version:5.9
// llama.cpp (MIT, ggml-org) as its official prebuilt xcframework, for Voice In's on-device
// formatting model. SwiftPM fetches the zip at resolve time and checks it against the checksum,
// so no binary lives in this repo. To update: pick a release, then
//   swift package compute-checksum llama-bNNNNN-xcframework.zip
// The macOS slice is universal (arm64 + x86_64) and needs macOS 13.3.
import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [.macOS("13.3")],
    products: [.library(name: "LlamaCpp", targets: ["llama"])],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11483/llama-b11483-xcframework.zip",
            checksum: "246f0e9254d6adfab4925c3e8d553a1853fb4c47bc50fac3a411c9bce60fadfb"
        ),
    ]
)
