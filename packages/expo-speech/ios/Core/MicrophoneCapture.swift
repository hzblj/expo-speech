import AVFoundation
import Foundation

/// The microphone, converted to the engine's format as it comes, optionally written to a WAV file and metered.
///
/// Survives a change of route (AirPods in or out): the input's format changes with it, so the tap is installed again
/// with a new converter, where a fixed converter would crash. A call or another app taking the session ends the
/// stream early instead of leaving it silent; `wasInterrupted` tells the two endings apart.
///
/// `stop` may come at any time, from any thread: before `start` (the stream it returns is already over and the
/// microphone never opens), during it (it tears down once the engine runs), or after. `muted` sends silence in place of
/// what the microphone hears, so the stream, the recording and the times go on without a gap.
public final class MicrophoneCapture: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var recordURL: URL?
    /// Seconds between volume reports; 0 for none.
    public var volumeInterval: Double
    public var voiceProcessing: Bool
    /// Set the audio session up (iOS) and tear it down afterwards.
    public var managesAudioSession: Bool

    public init(recordURL: URL? = nil, volumeInterval: Double = 0, voiceProcessing: Bool = false, managesAudioSession: Bool = true) {
      self.recordURL = recordURL
      self.volumeInterval = volumeInterval
      self.voiceProcessing = voiceProcessing
      self.managesAudioSession = managesAudioSession
    }
  }

  private enum Phase {
    case idle, starting, running, stopped
  }

  private let configuration: Configuration
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var phase = Phase.idle
  private var format: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var file: AVAudioFile?
  private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
  private var frames: AVAudioFramePosition = 0
  private var lastVolume = Date.distantPast
  private var observers: [NSObjectProtocol] = []
  private var interrupted = false
  private var _muted = false
  private var levelMeter: LevelMeter?

  /// The level in dBFS, every `volumeInterval`.
  public var onVolume: (@Sendable (Float) -> Void)?
  /// Once, when the microphone runs.
  public var onStart: (@Sendable () -> Void)?
  /// The root mean square of every `levelInterval` of audio, from 0 to 1 (0 while muted), for a live meter.
  public var onLevel: (@Sendable (Float) -> Void)?
  public static let levelInterval = 0.08

  public var muted: Bool {
    get { lock.withLock { _muted } }
    set { lock.withLock { _muted = newValue } }
  }

  public init(_ configuration: Configuration) {
    self.configuration = configuration
  }

  /// Seconds captured so far.
  public var duration: Double {
    lock.withLock { format.map { Double(frames) / $0.sampleRate } ?? 0 }
  }

  /// Whether a call or another app ended the capture, rather than `stop`.
  public var wasInterrupted: Bool {
    lock.withLock { interrupted }
  }

  /// Neither started nor stopped: no engine has asked for the microphone yet.
  public var isIdle: Bool {
    lock.withLock { phase == .idle }
  }

  /// `start` is opening the microphone and has not finished.
  public var isStarting: Bool {
    lock.withLock { phase == .starting }
  }

  /// Starts capturing. Chunks come in `format`, timed from the start of the capture.
  public func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AudioChunk, Error> {
    let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream(bufferingPolicy: .unbounded)

    let proceed = lock.withLock { () -> Bool in
      guard phase == .idle else {
        return false
      }
      phase = .starting
      self.format = format
      self.continuation = continuation
      self.frames = 0
      return true
    }
    // Stopped before it started: nothing to open.
    guard proceed else {
      continuation.finish()
      return stream
    }

    continuation.onTermination = { [weak self] _ in
      self?.stop()
    }

    do {
      #if os(iOS)
        guard AVAudioSession.sharedInstance().isInputAvailable else {
          throw SpeechFailure(.audio, "There is no microphone input")
        }
        if configuration.managesAudioSession {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(
            .playAndRecord, mode: configuration.voiceProcessing ? .voiceChat : .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
          try session.setActive(true)
        }
        observeSession()
      #endif

      if configuration.voiceProcessing {
        try engine.inputNode.setVoiceProcessingEnabled(true)
      }
      if let url = configuration.recordURL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recording = try AVAudioFile(
          forWriting: url,
          settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
          ],
          commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        lock.withLock { file = recording }
      }

      try installTap()
      engine.prepare()
      try engine.start()

      let observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in
        self?.restart()
      }
      lock.withLock { observers.append(observer) }
    } catch {
      let failure = SpeechFailure(.audio, "The microphone could not start: \(error.localizedDescription)")
      lock.withLock { phase = .running }
      finish(throwing: failure)
      throw failure
    }

    // A stop that came while the engine started found nothing to stop: it is honoured now.
    let stoppedMeanwhile = lock.withLock { () -> Bool in
      if phase == .stopped {
        return true
      }
      phase = .running
      return false
    }
    if stoppedMeanwhile {
      tearDown()
      continuation.finish()
    } else {
      onStart?()
    }
    return stream
  }

  /// Stops capturing; the stream ends once the chunks already captured are read.
  public func stop() {
    finish(throwing: nil)
  }

  private func installTap() throws {
    guard let format = lock.withLock({ self.format }) else {
      return
    }
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)

    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw SpeechFailure(.audio, "There is no microphone input")
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
      throw SpeechFailure(.audio, "The microphone's audio cannot be converted to \(format)")
    }

    lock.withLock { self.converter = converter }
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.process(buffer)
    }
  }

  private func restart() {
    guard lock.withLock({ phase == .running }) else {
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    do {
      try installTap()
      engine.prepare()
      try engine.start()
    } catch {
      finish(throwing: SpeechFailure(.audio, "The microphone stopped after a route change: \(error.localizedDescription)"))
    }
  }

  private func process(_ input: AVAudioPCMBuffer) {
    let (format, converter, continuation, muted) = lock.withLock {
      (self.format, self.converter, self.continuation, _muted)
    }
    meter(input, muted: muted)
    measureLevel(input, muted: muted)

    guard let format, let converter, let continuation else {
      return
    }

    let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64

    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return
    }

    var consumed = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return input
    }

    guard status != .error, output.frameLength > 0 else {
      return
    }
    if muted {
      for buffer in UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList) {
        if let data = buffer.mData {
          memset(data, 0, Int(buffer.mDataByteSize))
        }
      }
    }

    let (start, file) = lock.withLock { () -> (CMTime, AVAudioFile?) in
      let start = CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))
      frames += AVAudioFramePosition(output.frameLength)
      return (start, self.file)
    }

    try? file?.write(from: output)
    continuation.yield(AudioChunk(buffer: output, start: start))
  }

  /// Reports each `levelInterval` of audio as it fills. A route change may change the rate, and the stretch with it.
  private func measureLevel(_ buffer: AVAudioPCMBuffer, muted: Bool) {
    guard let onLevel, let channel = buffer.floatChannelData?[0] else {
      return
    }
    let frames = Int(buffer.format.sampleRate * Self.levelInterval)
    let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    let levels = lock.withLock { () -> [Float] in
      if levelMeter?.frames != frames {
        levelMeter = LevelMeter(frames: frames)
      }
      return levelMeter!.add(samples, muted: muted)
    }
    for level in levels {
      onLevel(level)
    }
  }

  private func meter(_ buffer: AVAudioPCMBuffer, muted: Bool) {
    guard configuration.volumeInterval > 0, let onVolume, let channel = buffer.floatChannelData?[0] else {
      return
    }

    let now = Date()
    let due = lock.withLock { () -> Bool in
      guard now.timeIntervalSince(lastVolume) >= configuration.volumeInterval else {
        return false
      }
      lastVolume = now
      return true
    }
    guard due else {
      return
    }
    if muted {
      onVolume(-160)
      return
    }

    let count = Int(buffer.frameLength)
    var sum: Float = 0
    for index in 0..<count {
      sum += channel[index] * channel[index]
    }
    let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
    onVolume(rms > 0 ? max(-160, 20 * log10(rms)) : -160)
  }

  private func finish(throwing error: Error?) {
    let (continuation, wasRunning) = lock.withLock { () -> (AsyncThrowingStream<AudioChunk, Error>.Continuation?, Bool) in
      switch phase {
      case .stopped:
        return (nil, false)
      case .idle, .starting:
        // `start` notices and finishes the stream itself once its engine runs; before it, there is nothing to stop.
        phase = .stopped
        return (nil, false)
      case .running:
        phase = .stopped
        let continuation = self.continuation
        self.continuation = nil
        return (continuation, true)
      }
    }

    guard wasRunning else {
      return
    }

    tearDown()

    if let error {
      continuation?.finish(throwing: error)
    } else {
      continuation?.finish()
    }
  }

  /// Stops the engine and lets go of the session, the file and the observers.
  private func tearDown() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    let observers = lock.withLock { () -> [NSObjectProtocol] in
      let observers = self.observers
      self.observers = []
      file = nil
      continuation = nil
      return observers
    }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }

    #if os(iOS)
      if configuration.managesAudioSession {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
    #endif
  }

  #if os(iOS)
    private func observeSession() {
      let center = NotificationCenter.default
      let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
        [weak self] notification in
        guard
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .began
        else {
          return
        }
        // End the stream as if stopped: what was heard is still finalized.
        self?.lock.withLock { self?.interrupted = true }
        self?.finish(throwing: nil)
      }
      let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) {
        [weak self] _ in
        self?.lock.withLock { self?.interrupted = true }
        self?.finish(throwing: nil)
      }
      lock.withLock { observers.append(contentsOf: [interruption, reset]) }
    }
  #endif
}
