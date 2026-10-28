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
    try await choose().run(input, sink: sink)
  }
}
