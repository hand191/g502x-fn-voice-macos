// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "G502XFnVoice",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "G502XFnVoice", targets: ["G502XFnVoice"]),
    ],
    targets: [
        .target(name: "G502XFnHIDCore"),
        .target(name: "G502XFnVoiceCore"),
        .executableTarget(
            name: "G502XFnVoice",
            dependencies: [
                "G502XFnHIDCore",
                "G502XFnVoiceCore",
            ]
        ),
        .testTarget(
            name: "G502XFnHIDCoreTests",
            dependencies: ["G502XFnHIDCore"]
        ),
        .testTarget(
            name: "G502XFnVoiceCoreTests",
            dependencies: ["G502XFnVoiceCore"]
        ),
    ]
)
