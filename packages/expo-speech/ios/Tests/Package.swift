// swift-tools-version:5.9
// The module's Foundation and Speech logic (`ios/Core`), tested on the Mac with `swift test`: the Speech framework is
// the same on macOS 26, so the engines run here against real audio, without an app. `Sources/ExpoSpeechCore` is a
// link to `../Core`, the files the pod compiles.
import PackageDescription

let package = Package(
  name: "ExpoSpeechCoreTests",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "ExpoSpeechCore", path: "Sources/ExpoSpeechCore"),
    .testTarget(name: "ExpoSpeechCoreTests", dependencies: ["ExpoSpeechCore"], path: "Tests/ExpoSpeechCoreTests"),
  ]
)
