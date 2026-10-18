// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoonlightMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "MoonlightMac",
            targets: ["MoonlightMac"]
        ),
        .library(
            name: "MoonlightCommonC",
            targets: ["MoonlightCommonC"]
        )
    ],
    targets: [
        .target(
            name: "MoonlightCommonC",
            path: "Sources/MoonlightCommonC",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("enet/include"),
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps/obl"),
                .define("HAS_FCNTL", to: "1"),
                .define("HAS_POLL", to: "1"),
                .define("HAS_GETADDRINFO", to: "1"),
                .define("HAS_GETNAMEINFO", to: "1"),
                .define("HAS_INET_PTON", to: "1"),
                .define("HAS_INET_NTOP", to: "1"),
                .define("HAS_MSGHDR_FLAGS", to: "1"),
                .define("HAS_SOCKLEN_T", to: "1"),
                .define("USE_APPLE_CRYPTO", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "MoonlightMac",
            dependencies: [
                "MoonlightCommonC"
            ],
            path: "Sources/MoonlightMac",
            resources: [
                .process("Pipeline/Metal/Shaders.metal")
            ],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("GameController"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "MoonlightMacTests",
            dependencies: [
                "MoonlightCommonC"
            ],
            path: "Tests/MoonlightMacTests"
        )
    ]
)
