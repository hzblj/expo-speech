import ExpoModulesCore
import Foundation

/// A failure as a JavaScript error whose `code` is the `SpeechErrorCode`.
final class SpeechException: Exception, @unchecked Sendable {
  private let failure: SpeechFailure

  init(_ failure: SpeechFailure) {
    self.failure = failure
    super.init(name: "SpeechException", description: failure.message, code: failure.code.rawValue)
  }

  override var reason: String {
    failure.message
  }

  override var code: String {
    failure.code.rawValue
  }
}

/// Where a finished transcript is kept, when the transcription has a `cacheKey`.
struct CacheSlot {
  let key: String
  let locale: String
  let engine: String
  let fingerprint: String
}

/// One transcription, shared with JavaScript as `Transcription`: a queued file or the microphone. Takes the engine's
/// results through `EngineSink`, keeps the transcript, and sends `update`, `stateChange`, `progress`, `speech` and
/// `volume` events.
final class TranscriptionObject: SharedObject, EngineSink, @unchecked Sendable {
  /// The microphone's level for native code that follows a transcription without JavaScript (expo-waveform's
  /// `LiveWaveformView`): posted with the transcription as the object every 80 ms of audio, `userInfo["level"]` the
  /// root mean square as a `Double` from 0 to 1, from the audio thread.
  static let audioLevel = Notification.Name("expo.audioLevel")

  enum Kind: String {
    case file, microphone
  }

  enum State: String {
    case queued, downloading, preparing, transcribing, paused, completed, cancelled, failed

    var isSettled: Bool {
      self == .completed || self == .cancelled || self == .failed
    }
  }

  let id = UUID().uuidString
  let kind: Kind
  let cacheSlot: CacheSlot?
  /// Higher first; equal priorities in order of arrival.
  let priority: Int
  let order: Int

  private let lock = NSLock()
  private var assembler: TranscriptAssembler
  private var _state: State = .queued
  private var _fromCache = false
  private var _progress: Double = 0
  private var _failure: SpeechFailure?
  private var waiters: [Promise] = []
  private var task: Task<Void, Never>?
  private var capture: MicrophoneCapture?
  private var autoStop: AutoStop?
  private var isPaused = false
  private var cancelRequested = false

  /// Called once, when it settles: the transcriber takes it out of its queue.
  var onSettled: ((TranscriptionObject) -> Void)?

  init(kind: Kind, locale: String, cacheSlot: CacheSlot?, priority: Int, order: Int) {
    self.kind = kind
    self.cacheSlot = cacheSlot
    self.priority = priority
    self.order = order
    self.assembler = TranscriptAssembler(locale: locale)
    super.init()
  }

  var cacheKey: String? { cacheSlot?.key }
  var state: State { lock.withLock { _state } }
  var fromCache: Bool { lock.withLock { _fromCache } }
  var progress: Double { lock.withLock { _progress } }
  var failure: SpeechFailure? { lock.withLock { _failure } }
  var transcript: Transcript { lock.withLock { assembler.transcript } }

  // MARK: Running

  /// Finished at once, from the cache.
  func complete(fromCache transcript: Transcript) {
    lock.withLock {
      assembler = TranscriptAssembler(locale: transcript.locale, finals: transcript.segments)
      assembler.duration = transcript.duration
      assembler.audioUri = transcript.audioUri
      _fromCache = true
      _progress = 1
    }
    settle(.completed, failure: nil)
  }

  /// Transcribes a file: downloads it when remote, then runs the engine over it.
  func runFile(uri: String, options: TranscribeOptions, engine: Task<SpeechEngine, Error>) {
    run(engine: engine) { [weak self] in
      guard let url = URL(string: uri) ?? URL(string: uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
        throw SpeechFailure(.audio, "\(uri) is not a URL")
      }
      if !url.isFileURL {
        self?.setState(.downloading)
      }
      let local = try await AudioDownloads.shared.localFile(for: url, headers: options.headers) { fraction in
        self?.emit(event: "progress", payload: ["phase": "downloading", "fraction": fraction])
      }
      self?.setState(.preparing)
      let reader = try await AudioFileReader(url: local, start: options.range?.start, end: options.range?.end)
      self?.lock.withLock {
        self?.assembler.duration = reader.duration
        self?.assembler.audioUri = local.absoluteString
      }
      return .file(reader)
    }
  }

  /// Transcribes the microphone until `stop`.
  func runMicrophone(options: ListenOptions, engine: Task<SpeechEngine, Error>) {
    let recording = options.record
      ? SpeechStorage.recordings.appendingPathComponent("\(UUID().uuidString).wav") : nil
    let capture = MicrophoneCapture(
      .init(
        recordURL: recording, volumeInterval: options.volumeInterval / 1000,
        voiceProcessing: options.voiceProcessing, managesAudioSession: options.audioSession != "manual"))

    capture.onVolume = { [weak self] level in
      self?.emit(event: "volume", payload: ["level": Double(level)])
    }
    capture.onLevel = { [weak self] level in
      guard let self else {
        return
      }
      NotificationCenter.default.post(name: Self.audioLevel, object: self, userInfo: ["level": Double(level)])
    }
    let autoStop = AutoStop(afterSilence: options.stopAfterSilence, withoutSpeech: options.stopWithoutSpeech) {
      [weak self] in
      self?.stop()
    }
    capture.onStart = { autoStop?.start() }
    lock.withLock {
      self.capture = capture
      self.autoStop = autoStop
    }

    run(engine: engine) { [weak self] in
      self?.lock.withLock { self?.assembler.audioUri = recording?.absoluteString }
      return .microphone(capture)
    }
  }

  private func run(engine: Task<SpeechEngine, Error>, input: @escaping () async throws -> EngineInput) {
    // Strong while it runs: the transcriber holds it anyway, and JavaScript may let go of it mid-run.
    let task = Task {
      do {
        // Cancelled between the queue and here: it never starts.
        if lock.withLock({ cancelRequested }) {
          throw CancellationError()
        }
        let engine = try await engine.value
        let input = try await input()
        try Task.checkCancellation()
        setState(.transcribing)
        try await engine.run(input, sink: self)
        stopCapture()
        finish()
      } catch {
        // However the engine ended, the microphone goes off with it.
        stopCapture()
        let failure = SpeechFailure.from(error)
        settle(failure.code == .cancelled ? .cancelled : .failed, failure: failure)
      }
    }
    lock.withLock { self.task = task }
  }

  private func stopCapture() {
    lock.withLock { capture }?.stop()
  }

  private func finish() {
    let (transcript, interrupted) = lock.withLock { () -> (Transcript, Bool) in
      assembler.finalizeVolatile()
      if let capture {
        assembler.duration = capture.duration
      }
      _progress = 1
      return (assembler.finalTranscript, capture?.wasInterrupted == true)
    }

    if lock.withLock({ cancelRequested }) {
      settle(.cancelled, failure: SpeechFailure(.cancelled, "The transcription was cancelled"))
      return
    }
    if let slot = cacheSlot, kind == .file {
      TranscriptCache.write(
        transcript, key: slot.key, locale: slot.locale, engine: slot.engine, fingerprint: slot.fingerprint)
    }
    // A call ended the listening early: what was heard is final, and the error says why it stopped.
    settle(.completed, failure: interrupted ? SpeechFailure(.interrupted, "Another app or a call took the microphone") : nil)
  }

  /// Stops listening and finalizes what was heard; for a file, cancels.
  func stop() {
    if kind == .microphone, let capture = lock.withLock({ self.capture }), !state.isSettled {
      capture.stop()
    } else {
      cancel()
    }
  }

  /// The microphone: silence until `resume`, in the state `paused`. Ignored for a file.
  func pause() {
    setPaused(true)
  }

  func resume() {
    setPaused(false)
  }

  private func setPaused(_ paused: Bool) {
    guard kind == .microphone else {
      return
    }
    let changed = lock.withLock { () -> (MicrophoneCapture?, AutoStop?, Bool)? in
      guard !_state.isSettled, isPaused != paused else {
        return nil
      }
      isPaused = paused
      return (capture, autoStop, _state == .transcribing || _state == .paused)
    }
    guard let (capture, autoStop, running) = changed else {
      return
    }
    capture?.muted = paused
    autoStop?.setPaused(paused)
    if running {
      setState(paused ? .paused : .transcribing)
    }
  }

  func cancel() {
    let (task, capture, wasQueued) = lock.withLock { () -> (Task<Void, Never>?, MicrophoneCapture?, Bool) in
      cancelRequested = true
      return (self.task, self.capture, _state == .queued && self.task == nil)
    }
    if wasQueued {
      settle(.cancelled, failure: SpeechFailure(.cancelled, "The transcription was cancelled"))
      return
    }
    capture?.stop()
    task?.cancel()
  }

  // MARK: State

  /// `transcribing` and `paused` follow `isPaused`, read here: a pause that crosses the start, or a late call, still
  /// ends in the right one.
  private func setState(_ requested: State) {
    let changed = lock.withLock { () -> State? in
      let state = requested == .transcribing || requested == .paused ? (isPaused ? .paused : .transcribing) : requested
      guard !_state.isSettled, _state != state else {
        return nil
      }
      _state = state
      return state
    }
    if let changed {
      emit(event: "stateChange", payload: ["state": changed.rawValue, "error": NSNull()])
    }
  }

  private func settle(_ state: State, failure: SpeechFailure?) {
    let (waiters, transcript) = lock.withLock { () -> ([Promise]?, Transcript) in
      guard !_state.isSettled else {
        return (nil, assembler.transcript)
      }
      _state = state
      _failure = failure
      autoStop?.cancel()
      let waiters = self.waiters
      self.waiters = []
      return (waiters, assembler.transcript)
    }
    guard let waiters else {
      return
    }

    emit(event: "stateChange", payload: ["state": state.rawValue, "error": failure.map { $0.json as Any } ?? NSNull()])
    for promise in waiters {
      resolve(promise, state: state, failure: failure, transcript: transcript)
    }
    onSettled?(self)
    onSettled = nil
  }

  private func resolve(_ promise: Promise, state: State, failure: SpeechFailure?, transcript: Transcript) {
    if state == .completed {
      promise.resolve(transcript.json)
    } else {
      promise.reject(SpeechException(failure ?? SpeechFailure(.cancelled, "The transcription was cancelled")))
    }
  }

  /// Resolves the promise once the transcription settles.
  func wait(_ promise: Promise) {
    let settled = lock.withLock { () -> (State, SpeechFailure?, Transcript)? in
      guard _state.isSettled else {
        waiters.append(promise)
        return nil
      }
      return (_state, _failure, assembler.transcript)
    }
    if let (state, failure, transcript) = settled {
      resolve(promise, state: state, failure: failure, transcript: transcript)
    }
  }

  // MARK: EngineSink

  func engine(recognized result: RecognizedResult) {
    let update = lock.withLock { () -> [String: Any]? in
      guard !_state.isSettled else {
        return nil
      }
      let segments = result.isFinal ? assembler.appendFinal([result]) : []
      if !result.isFinal {
        assembler.setVolatile(result)
      }
      return [
        "segments": segments.map(\.json),
        "volatile": assembler.currentVolatile.map { $0.json as Any } ?? NSNull(),
      ]
    }
    if let update {
      lock.withLock { autoStop }?.heard(result.text)
      emit(event: "update", payload: update)
    }
  }

  func engine(detectedSpeech detected: Bool, at time: Double) {
    lock.withLock { autoStop }?.speech(detected)
    emit(event: "speech", payload: ["detected": detected, "time": time])
  }

  func engine(progress fraction: Double, phase: String) {
    if phase == "transcribing" {
      lock.withLock { _progress = fraction }
    }
    emit(event: "progress", payload: ["phase": phase, "fraction": fraction])
  }
}
