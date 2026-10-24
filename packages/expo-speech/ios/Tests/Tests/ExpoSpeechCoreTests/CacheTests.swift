import XCTest

@testable import ExpoSpeechCore

final class CacheTests: XCTestCase {
  func testATranscriptComesBackFromTheCache() {
    let assembler = TranscriptAssembler(locale: "en-GB")
    assembler.appendFinal([RecognizedResult(runs: [RecognizedRun(text: "Box", start: 0, end: 0.4)], start: 0, end: 0.4, isFinal: true)])
    let key = UUID().uuidString

    TranscriptCache.write(assembler.finalTranscript, key: key, engine: "analyzer", fingerprint: "f")

    XCTAssertEqual(TranscriptCache.read(key: key, locale: "en-GB", engine: "analyzer", fingerprint: "f")?.text, "Box")
    XCTAssertNil(TranscriptCache.read(key: key, locale: "en-GB", engine: "analyzer", fingerprint: "other"))
    XCTAssertNil(TranscriptCache.read(key: key, locale: "cs-CZ", engine: "analyzer", fingerprint: "f"))
  }

  func testAudioThatMovedWithTheContainerIsFoundAgain() throws {
    let name = "\(UUID().uuidString).mp3"
    try FileManager.default.createDirectory(at: SpeechStorage.audio, withIntermediateDirectories: true)
    let current = SpeechStorage.audio.appendingPathComponent(name)
    try Data([1, 2, 3]).write(to: current)
    defer { try? FileManager.default.removeItem(at: current) }

    let stale = "file:///private/var/containers/Data/Application/OLD/Library/Caches/expo-speech/audio/\(name)"
    var transcript = Transcript(locale: "en-GB")
    transcript.audioUri = stale
    let key = UUID().uuidString
    TranscriptCache.write(transcript, key: key, engine: "analyzer", fingerprint: "f")

    XCTAssertEqual(TranscriptCache.read(key: key, locale: "en-GB", engine: "analyzer", fingerprint: "f")?.audioUri, current.absoluteString)
    XCTAssertNil(TranscriptCache.relocated("file:///gone/\(UUID().uuidString).mp3"))
    XCTAssertEqual(TranscriptCache.relocated("https://example.com/radio.mp3"), "https://example.com/radio.mp3")
  }
}
