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
        )
    ],
    targets: [
        .executableTarget(
            name: "VoiceGum",
            dependencies: ["VoiceGumCore", "VoiceGumServices", "VoiceGumPreferences", "VoiceGumKeychain", "VoiceGumFnKey"],
            path: "Sources/App",
            resources: [
                .copy("../../Frameworks/sense-voice"),
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
            dependencies: ["VoiceGumPreferences", "VoiceGumKeychain", "CQwenASR", "CZlib"],
            path: "Sources/Services"
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
        .target(
            name: "CQwenASR",
            path: "Sources/CQwenASR",
            sources: [
                "qwen_asr.c",
                "qwen_asr_audio.c",
                "qwen_asr_decoder.c",
                "qwen_asr_encoder.c",
                "qwen_asr_kernels.c",
                "qwen_asr_kernels_generic.c",
                "qwen_asr_kernels_neon.c",
                "qwen_asr_safetensors.c",
                "qwen_asr_tokenizer.c",
            ],
            cSettings: [
                .unsafeFlags(["-fno-modules"]),
                .define("USE_BLAS"),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
