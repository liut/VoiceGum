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
                .copy("../../Frameworks/sense-voice")
            ]
        ),
        .target(
            name: "VoiceGumCore",
            dependencies: ["VoiceGumServices", "VoiceGumPreferences", "VoiceGumKeychain", "VoiceGumFnKey"],
            path: "Sources/Core"
        ),
        .target(
            name: "VoiceGumServices",
            dependencies: ["VoiceGumPreferences", "VoiceGumKeychain"],
            path: "Sources/Services"
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
        )
    ],
    swiftLanguageModes: [.v6]
)
