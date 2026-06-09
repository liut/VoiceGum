// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceGum",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "VoiceGum",
            targets: ["VoiceGum"]
        ),
        .executable(
            name: "VoiceGumCLI",
            targets: ["VoiceGumCLI"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "VoiceGumCLI",
            dependencies: ["VoiceGumServices"],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "VoiceGum",
            dependencies: ["VoiceGumCore", "VoiceGumServices", "VoiceGumPreferences", "VoiceGumKeychain", "VoiceGumFnKey"],
            path: "Sources/App",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "VoiceGumCore",
            dependencies: ["VoiceGumServices", "VoiceGumPreferences", "VoiceGumKeychain", "VoiceGumFnKey"],
            path: "Sources/Core"
        ),
        .target(
            name: "VoiceGumServices",
            dependencies: ["VoiceGumPreferences", "VoiceGumKeychain", "CZlib", "CAsrEngine"],
            path: "Sources/Services"
        ),
        .target(
            name: "CAsrEngine",
            path: "Sources/CAsrEngine",
            sources: [
                "asr_engine.cpp",
                "common.cc",
                "sense_voice_adapter.cpp",
                "sense-voice.cc",
                "sense-voice-encoder.cc",
                "sense-voice-decoder.cc",
                "sense-voice-frontend.cc",
                "silero-vad.cc",
                "fftsg.cc",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-fno-modules", "-std=c++17",
                              "-I", "Sources/CAsrEngine/private_headers",
                              "-Wno-unused-command-line-argument"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "Sources/CAsrEngine/libs",
                    "-lggml", "-lggml-base", "-lggml-cpu", "-lggml-metal",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            sources: ["gzip_helper.c"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fno-modules"]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "VoiceGumPreferences",
            dependencies: [],
            path: "Sources/Preferences"
        ),
        .target(
            name: "VoiceGumKeychain",
            dependencies: [],
            path: "Sources/Keychain"
        ),
        .target(
            name: "VoiceGumFnKey",
            dependencies: [],
            path: "Sources/FnKey"
        ),
    ],
    swiftLanguageModes: [.v6]
)
