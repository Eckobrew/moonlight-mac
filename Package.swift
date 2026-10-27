// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoonlightMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "moonlight-mac",
            targets: ["MoonlightMac"]
        ),
        .library(
            name: "MoonlightCommonC",
            targets: ["MoonlightCommonC"]
        ),
        .library(
            name: "Copus",
            targets: ["Copus"]
        )
    ],
    targets: [
        .target(
            name: "Copus",
            path: "Sources/Copus",
            exclude: [
                "AUTHORS",
                "autogen.sh",
                "celt_headers.mk",
                "celt_sources.mk",
                "celt/arm",
                "celt/dump_modes",
                "celt/meson.build",
                "celt/opus_custom_demo.c",
                "celt/tests",
                "celt/x86",
                "ChangeLog",
                "cmake",
                "CMakeLists.txt",
                "configure.ac",
                "COPYING",
                "doc",
                "include/meson.build",
                "LICENSE_PLEASE_READ.txt",
                "m4",
                "m4/opus-intrinsics.m4",
                "Makefile.am",
                "Makefile.mips",
                "Makefile.unix",
                "meson_options.txt",
                "meson.build",
                "meson",
                "NEWS",
                "opus_headers.mk",
                "opus_sources.mk",
                "opus-uninstalled.pc.in",
                "opus.m4",
                "opus.pc.in",
                "README.draft",
                "README",
                "releases.sha2",
                "scripts/dump_rnn.py",
                "scripts/rnn_train.py",
                "silk_headers.mk",
                "silk_sources.mk",
                "silk/arm",
                "silk/fixed",
                "silk/meson.build",
                "silk/mips",
                "silk/tests",
                "silk/x86",
                "src/meson.build",
                "src/opus_compare.c",
                "src/opus_demo.c",
                "src/repacketizer_demo.c",
                "tests",
                "training",
                "update_version",
                "win32"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("celt/x86"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),

                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS", to: "1"),
                .define("FLOATING_POINT"),

                .define("HAVE_DLFCN_H", to: "1"),
                .define("HAVE_INTTYPES_H", to: "1"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
                .define("HAVE_MEMORY_H", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("HAVE_STDLIB_H", to: "1"),
                .define("HAVE_STRING_H", to: "1"),
                .define("HAVE_STRINGS_H", to: "1"),
                .define("HAVE_SYS_STAT_H", to: "1"),
                .define("HAVE_SYS_TYPES_H", to: "1"),
                .define("HAVE_UNISTD_H", to: "1")
            ]
        ),
        .target(
            name: "MoonlightCommonC",
            path: "Sources/MoonlightCommonC",
            exclude: ["LICENSE.txt", "enet/LICENSE", "nanors/LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("enet/include"),
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps/obl"),
                .headerSearchPath("../Copus/include"),
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
                "MoonlightCommonC",
                "Copus"
            ],
            path: "Sources/MoonlightMac",
            resources: [
                .process("Pipeline/Metal/Shaders.metal"),
                .process("Resources")
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
                .linkedFramework("Network"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "MoonlightMacTests",
            dependencies: [
                "MoonlightMac",
                "MoonlightCommonC",
                "Copus"
            ],
            path: "Tests/MoonlightMacTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
