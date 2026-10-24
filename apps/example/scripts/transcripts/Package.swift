// swift-tools-version:5.9
// Transcribes the example's weekend on the Mac with expo-speech's own engine (`ios/Core`, linked as
// `Sources/ExpoSpeechCore`): macOS 26 has the Speech framework iOS 26 has. `yarn transcripts` in apps/example.
import PackageDescription

let package = Package(
  name: "Transcripts",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "ExpoSpeechCore", path: "Sources/ExpoSpeechCore"),
    .executableTarget(name: "transcripts", dependencies: ["ExpoSpeechCore"], path: "Sources/transcripts"),
  ]
)
