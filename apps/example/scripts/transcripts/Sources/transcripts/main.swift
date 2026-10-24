import ExpoSpeechCore
import Foundation

/// Every message of `src/f1/radio.json`, transcribed by `SpeechAnalyzer` on the Mac into `src/f1/transcripts.json`: what
/// the example shows in the iOS Simulator, which cannot get or run Apple's speech models. On a device the example
/// transcribes for itself.
final class Collector: EngineSink, @unchecked Sendable {
  let assembler: TranscriptAssembler
  private let lock = NSLock()

  init(locale: String) {
    assembler = TranscriptAssembler(locale: locale)
  }

  func engine(recognized result: RecognizedResult) {
    lock.withLock {
      if result.isFinal {
        assembler.appendFinal([result])
      } else {
        assembler.setVolatile(result)
      }
    }
  }

  func engine(detectedSpeech detected: Bool, at time: Double) {}

  func engine(progress fraction: Double, phase: String) {}
}

/// Pit wall words a general model gets wrong; `src/speech.ts` gives the app's transcriber the same.
let jargon = [
  "box", "box box", "box this lap", "push", "copy", "DRS", "undercut", "overcut", "deg", "graining", "blistering",
  "tyres", "mediums", "softs", "hards", "inters", "safety car", "VSC", "pit wall", "Plan A", "Plan B",
  "lift and coast", "brake bias", "diff", "engine mode", "gap",
]

/// SpeechAnalyzer is macOS 26's, as it is iOS 26's.
@available(macOS 26.0, *)
func transcribeWeekend() async throws {
  let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "src/f1")
  let radio = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("radio.json"))) as! [String: Any]
  let drivers = radio["drivers"] as? [[String: Any]] ?? []
  let sessions = radio["sessions"] as? [[String: Any]] ?? []
  let urls = sessions.flatMap { ($0["messages"] as? [[String: Any]] ?? []).compactMap { $0["recording_url"] as? String } }

  var options = TranscriberOptions()
  options.locale = "en-GB"
  options.contextualStrings = drivers.flatMap { [$0["last_name"], $0["first_name"]].compactMap { $0 as? String } } + jargon

  var transcripts: [String: Any] = [:]
  let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("expo-speech-transcripts")
  try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

  for (index, url) in urls.enumerated() {
    let file = downloads.appendingPathComponent(URL(string: url)!.lastPathComponent)
    if !FileManager.default.fileExists(atPath: file.path) {
      let (temporary, _) = try await URLSession.shared.download(from: URL(string: url)!)
      try FileManager.default.moveItem(at: temporary, to: file)
    }

    let engine = try await AnalyzerEngine.make(options)
    let sink = Collector(locale: engine.localeIdentifier)
    try await engine.run(.file(try await AudioFileReader(url: file)), sink: sink)

    var transcript = sink.assembler.finalTranscript
    transcript.audioUri = nil
    transcripts[url] = transcript.json
    print("\(index + 1)/\(urls.count) \(transcript.words.count) words  \(transcript.text.prefix(60))")
  }

  let data = try JSONSerialization.data(withJSONObject: transcripts, options: [.sortedKeys])
  try data.write(to: folder.appendingPathComponent("transcripts.json"))
  print("\(transcripts.count) transcripts → \(folder.appendingPathComponent("transcripts.json").path)")
}

if #available(macOS 26.0, *) {
  try await transcribeWeekend()
} else {
  fatalError("SpeechAnalyzer needs macOS 26")
}
