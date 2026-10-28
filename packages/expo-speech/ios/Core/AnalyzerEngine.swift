import AVFoundation
import Foundation
import Speech

/// The transcriber module in use: `SpeechTranscriber`, or `DictationTranscriber` for dictation (and where the general
/// model is not available on the device).
@available(iOS 26.0, macOS 26.0, *)
enum TranscriberModule: @unchecked Sendable {
  case transcriber(SpeechTranscriber)
  case dictation(DictationTranscriber)

  var module: any SpeechModule {
    switch self {
    case .transcriber(let module): return module
    case .dictation(let module): return module
    }
  }

  /// Feeds every result to `handle` until the analyzer finishes.
  func forEachResult(_ handle: (RecognizedResult) -> Void) async throws {
    switch self {
    case .transcriber(let module):
      for try await result in module.results {
        handle(
          AnalyzerEngine.recognized(
            text: result.text, range: result.range, isFinal: result.isFinal, alternatives: result.alternatives))
      }
    case .dictation(let module):
      for try await result in module.results {
        handle(
          AnalyzerEngine.recognized(
            text: result.text, range: result.range, isFinal: result.isFinal, alternatives: result.alternatives))
      }
    }
  }
}

/// `SpeechAnalyzer` with a transcriber module and, for `detectSpeech`, a `SpeechDetector`. Runs on the device, with
/// models the system downloads per locale through `AssetInventory`.
@available(iOS 26.0, macOS 26.0, *)
public final class AnalyzerEngine: SpeechEngine, @unchecked Sendable {
  public let options: TranscriberOptions
  public let locale: Locale
  /// Dictation, asked for or because `SpeechTranscriber` is not available on this device.
  public let usesDictation: Bool
  public let name = "analyzer"

  public var localeIdentifier: String {
    locale.bcp47
  }

  init(options: TranscriberOptions, locale: Locale, usesDictation: Bool) {
    self.options = options
    self.locale = locale
    self.usesDictation = usesDictation
  }

  public static func make(_ options: TranscriberOptions) async throws -> AnalyzerEngine {
    let requested = options.locale.map { Locale(identifier: $0) } ?? Locale.current
    let dictation = options.mode == .dictation || !SpeechTranscriber.isAvailable
    let resolved =
      dictation
      ? await DictationTranscriber.supportedLocale(equivalentTo: requested)
      : await SpeechTranscriber.supportedLocale(equivalentTo: requested)

    guard let resolved else {
      throw SpeechFailure(.localeUnavailable, "\(requested.bcp47) is not supported for \(dictation ? "dictation" : "transcription")")
    }
    return AnalyzerEngine(options: options, locale: resolved, usesDictation: dictation)
  }

  /// The modules of one analysis. Modules belong to one analyzer, so every run makes its own.
  func makeModules() -> (TranscriberModule, SpeechDetector?) {
    let attributes: Set<SpeechTranscriber.ResultAttributeOption> = [.audioTimeRange, .transcriptionConfidence]
    let transcriber: TranscriberModule

    if usesDictation {
      var hints: Set<DictationTranscriber.ContentHint> = []
      for hint in options.ios.contentHints {
        switch hint {
        case "shortForm": hints.insert(.shortForm)
        case "farField": hints.insert(.farField)
        case "atypicalSpeech": hints.insert(.atypicalSpeech)
        default: break
        }
      }
      if let model = options.ios.customLanguageModel, let configuration = Self.configuration(of: model) {
        hints.insert(.customizedLanguage(modelConfiguration: configuration))
      }

      var transcription: Set<DictationTranscriber.TranscriptionOption> = []
      if options.punctuation { transcription.insert(.punctuation) }
      if options.ios.emoji { transcription.insert(.emoji) }
      if options.maskOffensiveWords == true { transcription.insert(.etiquetteReplacements) }

      var reporting: Set<DictationTranscriber.ReportingOption> = []
      if options.volatileResults { reporting.insert(.volatileResults) }
      if options.alternatives { reporting.insert(.alternativeTranscriptions) }
      if options.ios.frequentFinalization { reporting.insert(.frequentFinalization) }

      transcriber = .dictation(
        DictationTranscriber(
          locale: locale, contentHints: hints, transcriptionOptions: transcription, reportingOptions: reporting,
          attributeOptions: [.audioTimeRange, .transcriptionConfidence]))
    } else {
      var transcription: Set<SpeechTranscriber.TranscriptionOption> = []
      if options.maskOffensiveWords == true { transcription.insert(.etiquetteReplacements) }

      var reporting: Set<SpeechTranscriber.ReportingOption> = []
      if options.volatileResults { reporting.insert(.volatileResults) }
      if options.alternatives { reporting.insert(.alternativeTranscriptions) }
      if options.ios.fastResults { reporting.insert(.fastResults) }

      transcriber = .transcriber(
        SpeechTranscriber(
          locale: locale, transcriptionOptions: transcription, reportingOptions: reporting,
          attributeOptions: attributes))
    }

    let detector = options.detectSpeech.map { sensitivity -> SpeechDetector in
      let level: SpeechDetector.SensitivityLevel =
        sensitivity == "low" ? .low : sensitivity == "high" ? .high : .medium
      return SpeechDetector(detectionOptions: .init(sensitivityLevel: level), reportResults: true)
    }
    return (transcriber, detector)
  }

  static func configuration(of model: CustomLanguageModelReference) -> SFSpeechLanguageModel.Configuration? {
    guard let languageModel = URL(string: model.languageModel) else {
      return nil
    }
    let vocabulary = model.vocabulary.flatMap { URL(string: $0) }
    return SFSpeechLanguageModel.Configuration(
      languageModel: languageModel, vocabulary: vocabulary, weight: model.weight.map { NSNumber(value: $0) })
  }

  private var analyzerOptions: SpeechAnalyzer.Options {
    let retention: SpeechAnalyzer.Options.ModelRetention =
      switch options.ios.modelRetention {
      case "whileInUse": .whileInUse
      case "processLifetime": .processLifetime
      default: .lingering
      }
    let priority: TaskPriority =
      switch options.ios.priority {
      case "background": .background
      case "utility": .utility
      case "low": .low
      case "medium": .medium
      case "high": .high
      default: .userInitiated
      }

    #if compiler(>=6.4)
      if #available(iOS 27.0, macOS 27.0, *), options.ios.ignoresResourceLimits {
        return SpeechAnalyzer.Options(
          priority: priority, modelRetention: retention, ignoresResourceLimits: true)
      }
    #endif
    return SpeechAnalyzer.Options(priority: priority, modelRetention: retention)
  }

  private var context: AnalysisContext? {
    guard !options.contextualStrings.isEmpty else {
      return nil
    }
    let context = AnalysisContext()
    context.contextualStrings = [.general: options.contextualStrings]
    return context
  }

  /// A model the iOS Simulator could not get or run: the simulator's doing, not the locale's. Some simulator runtimes
  /// (iOS 26.5's offers no audio format, iOS 27.0's never installs the asset) cannot transcribe at all, where a device
  /// downloads the same model and does.
  static func onSimulator(_ failure: SpeechFailure) -> SpeechFailure {
    #if targetEnvironment(simulator)
      return SpeechFailure(
        .unsupported, "Speech recognition is unsupported in this iOS Simulator: transcribe on a device (\(failure.message))")
    #else
      return failure
    #endif
  }

  /// Installs the modules' assets when they are missing, reporting the download as the `installing` phase.
  static func ensureAssets(for modules: [any SpeechModule], download: Bool, sink: EngineSink?) async throws {
    do {
      try await installAssets(for: modules, download: download, sink: sink)
    } catch let failure as SpeechFailure where failure.code == .localeUnavailable {
      throw onSimulator(failure)
    }
  }

  private static func installAssets(for modules: [any SpeechModule], download: Bool, sink: EngineSink?) async throws {
    switch await AssetInventory.status(forModules: modules) {
    case .installed:
      return
    case .unsupported:
      throw SpeechFailure(.localeUnavailable, "The locale's model is not available on this device")
    default:
      guard download else {
        throw SpeechFailure(.localeUnavailable, "The locale's model is not installed")
      }
    }

    let request: AssetInstallationRequest?
    do {
      request = try await AssetInventory.assetInstallationRequest(supporting: modules)
    } catch {
      throw SpeechFailure(.localeUnavailable, "The locale's model cannot be installed: \(error.localizedDescription)")
    }
    guard let request else {
      return
    }

    let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
      sink?.engine(progress: progress.fractionCompleted, phase: "installing")
    }
    defer { observation.invalidate() }

    do {
      try await request.downloadAndInstall()
    } catch {
      throw SpeechFailure(.localeUnavailable, "The locale's model could not be downloaded: \(error.localizedDescription)")
    }
  }

  /// Whether the models are on the device, so a run starts without a download.
  public var isInstalled: Bool {
    get async {
      let (transcriber, detector) = makeModules()
      return await AssetInventory.status(forModules: [transcriber.module] + (detector.map { [$0] } ?? [])) == .installed
    }
  }

  /// Downloads the models when they are missing, without loading them.
  public func install() async throws {
    let (transcriber, detector) = makeModules()
    try await Self.ensureAssets(for: [transcriber.module] + (detector.map { [$0] } ?? []), download: true, sink: nil)
  }

  public func prepare(download: Bool, sink: EngineSink?) async throws {
    let (transcriber, detector) = makeModules()
    let modules = [transcriber.module] + (detector.map { [$0] } ?? [])

    try await Self.ensureAssets(for: modules, download: download, sink: sink)

    let analyzer = SpeechAnalyzer(modules: modules, options: analyzerOptions)
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    try await analyzer.prepareToAnalyze(in: format)
    await analyzer.cancelAndFinishNow()
  }

  public func run(_ input: EngineInput, sink: EngineSink) async throws {
    let (transcriber, detector) = makeModules()
    let modules = [transcriber.module] + (detector.map { [$0] } ?? [])

    try await Self.ensureAssets(for: modules, download: true, sink: sink)

    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
      throw Self.onSimulator(SpeechFailure(.unsupported, "No audio format suits the speech models"))
    }

    let analyzer = SpeechAnalyzer(modules: modules, options: analyzerOptions)

    if let context {
      try await analyzer.setContext(context)
    }

    let inputs: AnalyzerInputs
    var duration: Double?

    switch input {
    case .file(let reader):
      inputs = AnalyzerInputs(try reader.chunks(in: format))
      duration = reader.range.upperBound - reader.range.lowerBound
    case .microphone(let capture):
      // A transcription cancelled while the model loaded never opens the microphone.
      try Task.checkCancellation()
      inputs = AnalyzerInputs(try capture.start(format: format))
    }

    let total = duration
    let offset: Double = {
      if case .file(let reader) = input {
        return reader.range.lowerBound
      }
      return 0
    }()

    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await transcriber.forEachResult { result in
            sink.engine(recognized: result)
            if let total, total > 0 {
              sink.engine(progress: min(1, max(0, (result.end - offset) / total)), phase: "transcribing")
            }
          }
        }
        if let detector {
          group.addTask {
            for try await result in detector.results {
              sink.engine(detectedSpeech: result.speechDetected, at: result.range.start.seconds)
            }
          }
        }

        if let last = try await analyzer.analyzeSequence(inputs) {
          try await analyzer.finalizeAndFinish(through: last)
        } else {
          await analyzer.cancelAndFinishNow()
        }
        try await group.waitForAll()
      }
    } onCancel: {
      inputs.cancel()
      Task { await analyzer.cancelAndFinishNow() }
    }

    if total != nil {
      sink.engine(progress: 1, phase: "transcribing")
    }
  }

  /// A result as text runs: final results keep the time Apple gives every word; a volatile result's times cover the
  /// whole stretch still being revised, so its words are left to be estimated.
  static func recognized(
    text: AttributedString, range: CMTimeRange, isFinal: Bool, alternatives: [AttributedString]
  ) -> RecognizedResult {
    var runs: [RecognizedRun] = []

    for run in text.runs {
      let piece = String(text[run.range].characters)
      let time = isFinal ? run.audioTimeRange : nil
      let start = time.flatMap { $0.start.isNumeric ? $0.start.seconds : nil }
      let end = time.flatMap { $0.end.isNumeric ? $0.end.seconds : nil }

      runs.append(
        RecognizedRun(text: piece, start: start, end: end, confidence: isFinal ? run.transcriptionConfidence : nil))
    }

    let main = String(text.characters)
    let others = alternatives.map { String($0.characters) }.filter { $0 != main }

    return RecognizedResult(
      runs: runs, start: range.start.isNumeric ? range.start.seconds : 0,
      end: range.end.isNumeric ? range.end.seconds : 0, isFinal: isFinal, alternatives: others)
  }
}

/// Audio chunks from a file or the microphone, as the analyzer's input.
@available(iOS 26.0, macOS 26.0, *)
struct AnalyzerInputs: AsyncSequence, @unchecked Sendable {
  typealias Element = AnalyzerInput

  private let source: ChunkSource

  init(_ chunks: AudioFileReader.Chunks) {
    source = ChunkSource(file: chunks)
  }

  init(_ stream: AsyncThrowingStream<AudioChunk, Error>) {
    source = ChunkSource(stream: stream)
  }

  func cancel() {
    source.cancel()
  }

  func makeAsyncIterator() -> Iterator {
    Iterator(source: source)
  }

  struct Iterator: AsyncIteratorProtocol {
    let source: ChunkSource

    mutating func next() async throws -> AnalyzerInput? {
      guard let chunk = try await source.next() else {
        return nil
      }
      return AnalyzerInput(buffer: chunk.buffer, bufferStartTime: chunk.start)
    }
  }
}

/// The one iterator behind an input sequence, which the analyzer reads once.
final class ChunkSource: @unchecked Sendable {
  private let chunks: AudioFileReader.Chunks?
  private var fileIterator: AudioFileReader.Chunks.Iterator?
  private var streamIterator: AsyncThrowingStream<AudioChunk, Error>.AsyncIterator?

  init(file chunks: AudioFileReader.Chunks) {
    self.chunks = chunks
    fileIterator = chunks.makeAsyncIterator()
  }

  init(stream: AsyncThrowingStream<AudioChunk, Error>) {
    chunks = nil
    streamIterator = stream.makeAsyncIterator()
  }

  func next() async throws -> AudioChunk? {
    if fileIterator != nil {
      return try await fileIterator!.next()
    }
    return try await streamIterator?.next()
  }

  func cancel() {
    chunks?.cancel()
  }
}
