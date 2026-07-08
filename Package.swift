// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: ".",
            exclude: [
                "build.sh",
                "Info.plist",
                "AppIcon.icns",
                "AppIcon_preview.png",
                "generate_icon.py",
                "README.md",
                "AGENTS.md",
                "CONTEXT.md",
                "docs",
                "CODE_REVIEW_REPORT.md",
                "MeetingRecorder.app",
                "MeetingRecorder.dmg",
            ],
            sources: [
                "MeetingRecorderApp.swift",
                "AudioRecorder.swift",
                "DefaultInputWatcher.swift",
                "LiveCaptions.swift",
                "CaptionPanel.swift",
                "NotesWriter.swift",
                "SummaryClient.swift",
                "SummaryServerPanel.swift",
            ]
        )
    ]
)
