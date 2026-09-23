// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Newton",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NewtonCore", targets: ["NewtonCore"]),
        .library(name: "NewtonLocal", targets: ["NewtonLocal"])
    ],
    targets: [
        .target(name: "NewtonCore"),
        .binaryTarget(name: "llama-cpp",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9049/llama-b9049-xcframework.zip",
            checksum: "49c374bf78d98f53bfb3571b2285d315351ca6a5c1112191ae6f8b2616dec1d1"),
        .target(name: "NewtonLocal", dependencies: ["NewtonCore", "llama-cpp"]),
        .testTarget(name: "NewtonCoreTests", dependencies: ["NewtonCore"])
    ],
    swiftLanguageModes: [.v5]
)
