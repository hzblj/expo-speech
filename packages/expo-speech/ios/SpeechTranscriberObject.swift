import ExpoModulesCore
import Foundation

/// A recognizer for one configuration, shared with JavaScript as `SpeechTranscriber`. Owns the queue of file
/// transcriptions: runs up to `maxConcurrent` at once, highest priority first, hands out the transcription already
/// running for a `cacheKey`, and answers from the cache without queueing at all.
final class SpeechTranscriberObject: SharedObject, @unchecked Sendable {
  /// The microphone is one: a second `listen` anywhere in the app is refused while one runs.
  private static let microphone = NSLock()
  nonisolated(unsafe) private static weak var listening: TranscriptionObject?

  let options: TranscriberOptions
  /// The engine, made once: resolving the locale is asynchronous on iOS 26.
  let engine: Task<SpeechEngine, Error>
  /// The locale as asked for, until the engine says which it resolved to.
  private let requestedLocale: String
  private let lock = NSLock()
  private var resolvedLocale: String?
  /// Waiting transcriptions with their sources, highest priority first.
  private var queue: [(transcription: TranscriptionObject, uri: String, options: TranscribeOptions)] = []
  private var running: [TranscriptionObject] = []
  private var order = 0

  init(options: TranscriberOptions) {
    self.options = options
    self.requestedLocale = (options.locale.map { Locale(identifier: $0) } ?? Locale.current).identifier(.bcp47)
    self.engine = Task { try await SpeechEngines.make(options) }
    super.init()

    Task { [weak self] in
      if let engine = try? await self?.engine.value {
        self?.lock.withLock { self?.resolvedLocale = engine.localeIdentifier }
      }
    }
  }

  var locale: String {
    lock.withLock { resolvedLocale ?? requestedLocale }
  }

  var engineName: String {
    switch options.ios.engine {
    case .analyzer: return "analyzer"
    case .recognizer: return "recognizer"
    case .auto: return SpeechEngines.analyzerAvailable ? "analyzer" : "recognizer"
    }
  }

  var pending: Int {
    lock.withLock { queue.count + running.count }
  }

  func prepare(download: Bool) async throws {
    try await engine.value.prepare(download: download, sink: nil)
  }

  // MARK: Files

  func transcribe(uri: String, options transcribeOptions: TranscribeOptions) -> TranscriptionObject {
    let slot = transcribeOptions.cacheKey.map {
      CacheSlot(key: $0, locale: requestedLocale, engine: engineName, fingerprint: cacheFingerprint(transcribeOptions))
    }
    let priority = transcribeOptions.priority == "high" ? 1 : transcribeOptions.priority == "low" ? -1 : 0
    // Read before taking the lock: the getter takes it too, and NSLock is not reentrant.
    let locale = self.locale

    let transcription = lock.withLock { () -> TranscriptionObject in
      if let key = slot?.key, let existing = (running + queue.map(\.transcription)).first(where: { $0.cacheKey == key }) {
        return existing
      }
      order += 1
      return TranscriptionObject(kind: .file, locale: locale, cacheSlot: slot, priority: priority, order: order)
    }

    if transcription.state != .queued
      || lock.withLock({ (running + queue.map(\.transcription)).contains { $0 === transcription } })
    {
      return transcription
    }

    if let slot, let cached = TranscriptCache.read(
      key: slot.key, locale: slot.locale, engine: slot.engine, fingerprint: slot.fingerprint)
    {
      transcription.complete(fromCache: cached)
      return transcription
    }

    transcription.onSettled = { [weak self] settled in
      self?.remove(settled)
    }
    // Queued with its source in one step: a pump on another thread never finds one without the other.
    lock.withLock {
      queue.append((transcription, uri, transcribeOptions))
      queue.sort { ($0.transcription.priority, -$0.transcription.order) > ($1.transcription.priority, -$1.transcription.order) }
    }
    pump()
    return transcription
  }

  /// What the transcript depends on besides the audio: the options, and the range when only a part is wanted.
  private func cacheFingerprint(_ transcribeOptions: TranscribeOptions) -> String {
    let range = transcribeOptions.range.map { "\($0.start ?? 0)-\($0.end ?? -1)" } ?? ""
    return options.fingerprint + ";" + range
  }

  private func pump() {
    while true {
      let next = lock.withLock { () -> (TranscriptionObject, String, TranscribeOptions)? in
        guard running.count < options.maxConcurrent, !queue.isEmpty else {
          return nil
        }
        let entry = queue.removeFirst()
        running.append(entry.transcription)
        return (entry.transcription, entry.uri, entry.options)
      }
      guard let (transcription, uri, transcribeOptions) = next else {
        return
      }
      transcription.runFile(uri: uri, options: transcribeOptions, engine: engine)
    }
  }

  private func remove(_ transcription: TranscriptionObject) {
    lock.withLock {
      queue.removeAll { $0.transcription === transcription }
      running.removeAll { $0 === transcription }
    }
    pump()
  }

  // MARK: Microphone

  func listen(options listenOptions: ListenOptions) throws -> TranscriptionObject {
    // Denied, the microphone records silence: a transcription that never hears anything, rather than an error.
    if Permissions.microphoneDenied {
      throw SpeechException(SpeechFailure(.permissionDenied, "The microphone is not allowed"))
    }
    let locale = self.locale
    let transcription = try Self.microphone.withLock { () throws -> TranscriptionObject in
      if let current = Self.listening, !current.state.isSettled {
        throw SpeechException(SpeechFailure(.busy, "The microphone is already being transcribed"))
      }
      let transcription = TranscriptionObject(kind: .microphone, locale: locale, cacheSlot: nil, priority: 0, order: 0)
      Self.listening = transcription
      return transcription
    }
    transcription.runMicrophone(options: listenOptions, engine: engine)
    return transcription
  }

  func cancelAll() {
    let all = lock.withLock { queue.map(\.transcription) + running }
    for transcription in all {
      transcription.cancel()
    }
  }

  override func sharedObjectWillRelease() {
    cancelAll()
    engine.cancel()
  }
}
