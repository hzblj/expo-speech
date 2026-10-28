import Foundation

/// `onDevice: 'preferred'` on iOS 26: the analyzer once its model is installed; until then `SFSpeechRecognizer`, which
/// may use Apple's servers, while the model installs in the background for the next run. The recognizer needs speech
/// authorization and, for the servers, the network: without them a run waits for the model, as `required` does. A
/// locale the analyzer has no model for at all always goes to the recognizer.
@available(iOS 26.0, macOS 26.0, *)
public final class PreferredEngine: SpeechEngine, @unchecked Sendable {
  public let analyzer: AnalyzerEngine?
  public let recognizer: RecognizerEngine?
  private let lock = NSLock()
  private var installing: Task<Void, Never>?

  init(analyzer: AnalyzerEngine?, recognizer: RecognizerEngine?) {
    self.analyzer = analyzer
    self.recognizer = recognizer
  }

  public static func make(_ options: TranscriberOptions) async throws -> PreferredEngine {
    let analyzer: AnalyzerEngine?
    do {
      analyzer = try await AnalyzerEngine.make(options)
    } catch let failure as SpeechFailure where failure.code == .localeUnavailable {
      analyzer = nil
    }
    let recognizer = try? RecognizerEngine.make(options)

    guard analyzer != nil || recognizer != nil else {
      let locale = options.locale.map { Locale(identifier: $0) } ?? Locale.current
      throw SpeechFailure(.localeUnavailable, "\(locale.bcp47) is not supported")
    }
    return PreferredEngine(analyzer: analyzer, recognizer: recognizer)
  }

  public var localeIdentifier: String {
    analyzer?.localeIdentifier ?? recognizer?.localeIdentifier ?? ""
  }

  public var name: String {
    analyzer?.name ?? "recognizer"
  }

  /// The engine for one run.
  func choose() async -> SpeechEngine {
    guard let analyzer else {
      return recognizer!
    }
    #if targetEnvironment(simulator)
      // The Simulator's on-device models hang or fail to load; Apple's servers work there.
      if let recognizer, recognizer.isUsable {
        return recognizer
      }
    #endif
    if await analyzer.isInstalled {
      return analyzer
    }
    guard let recognizer, recognizer.isUsable else {
      return analyzer
    }
    installInBackground(analyzer)
    return recognizer
  }

  /// Once at a time; a failed install is tried again on a later run.
  private func installInBackground(_ analyzer: AnalyzerEngine) {
    lock.withLock {
      guard installing == nil else {
        return
      }
      installing = Task.detached(priority: .utility) { [weak self] in
        try? await analyzer.install()
        self?.lock.withLock { self?.installing = nil }
      }
    }
  }

  public func prepare(download: Bool, sink: EngineSink?) async throws {
    // A download asked for is the analyzer's model, now.
    let engine: SpeechEngine
    if download, let analyzer {
      engine = analyzer
    } else {
      engine = await choose()
    }
    try await engine.prepare(download: download, sink: sink)
  }

  public func run(_ input: EngineInput, sink: EngineSink) async throws {
    let engine = await choose()
    guard let analyzer, engine === analyzer, case .microphone(let capture) = input, let recognizer, recognizer.isUsable
    else {
      try await engine.run(input, sink: sink)
      return
    }
    try await run(analyzer, fallingBackTo: recognizer, capture: capture, input: input, sink: sink)
  }

  /// Seconds the analyzer has to open the microphone before the recognizer takes over.
  static let analyzerStartGrace: Double = 4

  /// The analyzer, unless it fails or has not opened the microphone within `analyzerStartGrace`: loading its model
  /// can hang (the iOS 27 Simulator, where `AssetInventory` reports the model installed). The recognizer then takes the
  /// same microphone, which the analyzer never touched; the analyzer's run is cancelled, and its check before
  /// `capture.start` keeps it from opening the microphone should it ever resume.
  private func run(
    _ analyzer: AnalyzerEngine, fallingBackTo recognizer: RecognizerEngine, capture: MicrophoneCapture,
    input: EngineInput, sink: EngineSink
  ) async throws {
    let outcome = RunOutcome()
    let analyzerRun = Task {
      do {
        try await analyzer.run(input, sink: sink)
        outcome.finish(nil)
      } catch {
        outcome.finish(error)
        throw error
      }
    }

    try await withTaskCancellationHandler {
      let deadline = Date().addingTimeInterval(Self.analyzerStartGrace)
      while capture.isIdle, !outcome.isFinished, Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
      }
    } onCancel: {
      analyzerRun.cancel()
    }

    let analyzerFailed = outcome.isFinished && outcome.error.map { !($0 is CancellationError) } == true
    guard capture.isIdle, analyzerFailed || !outcome.isFinished else {
      try await withTaskCancellationHandler {
        try await analyzerRun.value
      } onCancel: {
        analyzerRun.cancel()
      }
      return
    }

    analyzerRun.cancel()
    try Task.checkCancellation()
    try await recognizer.run(input, sink: sink)
  }
}

/// How a run that nobody awaits yet ended.
private final class RunOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var failure: Error?

  var isFinished: Bool {
    lock.withLock { finished }
  }

  var error: Error? {
    lock.withLock { failure }
  }

  func finish(_ error: Error?) {
    lock.withLock {
      finished = true
      failure = error
    }
  }
}
