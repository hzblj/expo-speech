import AVFoundation
import XCTest

@testable import ExpoSpeechCore

/// Collects what an engine reports.
final class RecordingSink: EngineSink, @unchecked Sendable {
  let assembler: TranscriptAssembler
  private let lock = NSLock()
  private(set) var progress: [(String, Double)] = []
  private(set) var volatileCount = 0

  init(locale: String) {
    assembler = TranscriptAssembler(locale: locale)
  }

  func engine(recognized result: RecognizedResult) {
    lock.withLock {
      if result.isFinal {
        assembler.appendFinal([result])
      } else {
        volatileCount += 1
        assembler.setVolatile(result)
      }
    }
  }

  func engine(detectedSpeech detected: Bool, at time: Double) {}

  func engine(progress fraction: Double, phase: String) {
    lock.withLock { progress.append((phase, fraction)) }
  }
}

/// The analyzer against real speech: `say` reads a team radio line, and the engine must hear it with word times.
/// The Speech framework on macOS 26 is the one iOS 26 has.
final class EngineTests: XCTestCase {
  private static let line = "Box, box. Box this lap. Verstappen is two seconds behind, push now."

  private func speech(_ name: String, format: String, extension ext: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("expo-speech-tests")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let aiff = directory.appendingPathComponent("\(name).aiff")
    let url = directory.appendingPathComponent("\(name).\(ext)")

    if !FileManager.default.fileExists(atPath: url.path) {
      let say = Process()
      say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
      say.arguments = ["-v", "Daniel", "-o", aiff.path, Self.line]
      try say.run()
      say.waitUntilExit()

      let convert = Process()
      convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
      convert.arguments = ["-f", format, "-d", ext == "m4a" ? "aac" : "LEI16@44100", aiff.path, url.path]
      try convert.run()
      convert.waitUntilExit()
    }
    return url
  }

  func testTheFileReaderDecodesToTheEnginesFormat() async throws {
    let reader = try await AudioFileReader(url: try speech("radio", format: "mp4f", extension: "m4a"))
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    var frames: AVAudioFrameCount = 0
    var last = -1.0

    for try await chunk in try reader.chunks(in: format) {
      XCTAssertEqual(chunk.buffer.format.sampleRate, 16_000)
      XCTAssertGreaterThan(chunk.start.seconds, last)
      last = chunk.start.seconds
      frames += chunk.buffer.frameLength
    }

    XCTAssertGreaterThan(reader.duration, 4)
    XCTAssertEqual(Double(frames) / 16_000, reader.duration, accuracy: 0.2)
  }

  func testTheReaderReadsOnlyTheRange() async throws {
    let reader = try await AudioFileReader(url: try speech("radio", format: "mp4f", extension: "m4a"), start: 2, end: 3)
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    var first: Double?
    var frames: AVAudioFrameCount = 0

    for try await chunk in try reader.chunks(in: format) {
      first = first ?? chunk.start.seconds
      frames += chunk.buffer.frameLength
    }

    XCTAssertEqual(first ?? 0, 2, accuracy: 0.05)
    XCTAssertEqual(Double(frames) / 16_000, 1, accuracy: 0.1)
  }

  func testAMissingFileIsAnAudioError() async {
    do {
      _ = try await AudioFileReader(url: URL(fileURLWithPath: "/nonexistent.m4a"))
      XCTFail("no error")
    } catch {
      XCTAssertEqual(SpeechFailure.from(error).code, .audio)
    }
  }

  func testTheAnalyzerTranscribesAFileWithWordTimes() async throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("SpeechAnalyzer needs macOS 26")
    }
    var options = TranscriberOptions()
    options.locale = "en-GB"

    let engine = try await AnalyzerEngine.make(options)
    let sink = RecordingSink(locale: engine.localeIdentifier)
    let reader = try await AudioFileReader(url: try speech("radio", format: "WAVE", extension: "wav"))

    try await engine.run(.file(reader), sink: sink)

    let transcript = sink.assembler.transcript
    let text = transcript.text.lowercased()

    XCTAssertEqual(engine.localeIdentifier, "en-GB")
    XCTAssertTrue(text.contains("verstappen"), text)
    XCTAssertTrue(text.contains("push now"), text)
    XCTAssertTrue(transcript.segments.allSatisfy(\.isFinal))
    XCTAssertGreaterThan(transcript.words.count, 8)
    XCTAssertTrue(transcript.words.allSatisfy { $0.end >= $0.start })
    XCTAssertEqual(
      transcript.words.map(\.start), transcript.words.map(\.start).sorted(), "words must be in time order")

    let verstappen = transcript.words.first { $0.text.lowercased().hasPrefix("verstappen") }
    XCTAssertNotNil(verstappen)
    XCTAssertEqual(verstappen?.timing, "measured")
    XCTAssertGreaterThan(verstappen?.start ?? 0, 1.5)
    XCTAssertEqual(sink.progress.last?.0, "transcribing")
    XCTAssertEqual(sink.progress.last?.1, 1)
  }

  func testTheAnalyzerKeepsTimesRelativeToTheWholeFile() async throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("SpeechAnalyzer needs macOS 26")
    }
    var options = TranscriberOptions()
    options.locale = "en-GB"

    let engine = try await AnalyzerEngine.make(options)
    let sink = RecordingSink(locale: engine.localeIdentifier)
    let reader = try await AudioFileReader(url: try speech("radio", format: "WAVE", extension: "wav"), start: 2.6)

    try await engine.run(.file(reader), sink: sink)

    let words = sink.assembler.transcript.words
    XCTAssertFalse(words.isEmpty)
    XCTAssertGreaterThanOrEqual(words.first?.start ?? 0, 2.5)
    XCTAssertFalse(sink.assembler.transcript.text.lowercased().contains("box this"))
  }

  func testDictationHonoursContextualStrings() async throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("SpeechAnalyzer needs macOS 26")
    }
    var options = TranscriberOptions()
    options.locale = "en-GB"
    options.mode = .dictation
    options.contextualStrings = ["box this lap"]

    let engine = try await AnalyzerEngine.make(options)
    let sink = RecordingSink(locale: engine.localeIdentifier)
    try await engine.run(.file(try await AudioFileReader(url: try speech("radio", format: "WAVE", extension: "wav"))), sink: sink)

    XCTAssertTrue(engine.usesDictation)
    XCTAssertTrue(sink.assembler.transcript.text.lowercased().contains("lap"), sink.assembler.transcript.text)
  }

  func testAnUnsupportedLocaleFails() async throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("SpeechAnalyzer needs macOS 26")
    }
    var options = TranscriberOptions()
    options.locale = "tlh-Latn"

    do {
      _ = try await AnalyzerEngine.make(options)
      XCTFail("no error")
    } catch {
      XCTAssertEqual(SpeechFailure.from(error).code, .localeUnavailable)
    }
  }

  func testCancellingStopsTheAnalyzer() async throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("SpeechAnalyzer needs macOS 26")
    }
    var options = TranscriberOptions()
    options.locale = "en-GB"
    let engine = try await AnalyzerEngine.make(options)
    let sink = RecordingSink(locale: engine.localeIdentifier)
    let reader = try await AudioFileReader(url: try speech("radio", format: "WAVE", extension: "wav"))

    let task = Task { try await engine.run(.file(reader), sink: sink) }
    task.cancel()
    _ = try? await task.value
    // Ending at all is the point: a cancelled run must not hang.
  }
}
