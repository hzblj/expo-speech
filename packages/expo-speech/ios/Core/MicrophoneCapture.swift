import AVFoundation
import Foundation

/// The microphone, converted to the engine's format as it comes, optionally written to a WAV file and metered.
///
/// Survives a change of route (AirPods in or out): the input's format changes with it, so the tap is installed again
/// with a new converter, where a fixed converter would crash. A call or another app taking the session ends the
/// stream early instead of leaving it silent; `wasInterrupted` tells the two endings apart.
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

  private let configuration: Configuration
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private var format: AVAudioFormat?
  private var converter: AVAudioConverter?
  private var file: AVAudioFile?
  private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
  private var frames: AVAudioFramePosition = 0
  private var lastVolume = Date.distantPast
  private var observers: [NSObjectProtocol] = []
  private var running = false

  /// The level in dBFS, every `volumeInterval`.
  public var onVolume: (@Sendable (Float) -> Void)?
  public private(set) var wasInterrupted = false

  public init(_ configuration: Configuration) {
    self.configuration = configuration
  }

  /// Seconds captured so far.
  public var duration: Double {
    lock.withLock { format.map { Double(frames) / $0.sampleRate } ?? 0 }
  }

  /// Starts capturing. Chunks come in `format`, timed from the start of the capture.
  public func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AudioChunk, Error> {
    let (stream, continuation) = AsyncThrowingStream<AudioChunk, Error>.makeStream(bufferingPolicy: .unbounded)

    lock.withLock {
      self.format = format
      self.continuation = continuation
      self.frames = 0
      self.running = true
    }

    do {
      #if os(iOS)
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
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(
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
      }

      try installTap()
      engine.prepare()
      try engine.start()

      observers.append(
        NotificationCenter.default.addObserver(
          forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
          self?.restart()
        })
    } catch {
      finish(throwing: SpeechFailure(.audio, "The microphone could not start: \(error.localizedDescription)"))
      throw SpeechFailure(.audio, "The microphone could not start: \(error.localizedDescription)")
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
    guard lock.withLock({ running }) else {
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
    meter(input)

    let (format, converter, continuation) = lock.withLock { (self.format, self.converter, self.continuation) }

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

    let start = lock.withLock { () -> CMTime in
      let start = CMTime(value: frames, timescale: CMTimeScale(format.sampleRate))
      frames += AVAudioFramePosition(output.frameLength)
      return start
    }

    try? file?.write(from: output)
    continuation.yield(AudioChunk(buffer: output, start: start))
  }

  private func meter(_ buffer: AVAudioPCMBuffer) {
    guard configuration.volumeInterval > 0, let onVolume, let channel = buffer.floatChannelData?[0] else {
      return
    }

    let now = Date()

    guard now.timeIntervalSince(lastVolume) >= configuration.volumeInterval else {
      return
    }
    lastVolume = now

    let count = Int(buffer.frameLength)
    var sum: Float = 0
    for index in 0..<count {
      sum += channel[index] * channel[index]
    }
    let rms = count > 0 ? (sum / Float(count)).squareRoot() : 0
    onVolume(rms > 0 ? max(-160, 20 * log10(rms)) : -160)
  }

  private func finish(throwing error: Error?) {
    let continuation = lock.withLock { () -> AsyncThrowingStream<AudioChunk, Error>.Continuation? in
      guard running else {
        return nil
      }
      running = false
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }

    guard let continuation else {
      return
    }

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers = []
    file = nil

    #if os(iOS)
      if configuration.managesAudioSession {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
    #endif

    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }

  #if os(iOS)
    private func observeSession() {
      let center = NotificationCenter.default

      observers.append(
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
          [weak self] notification in
          guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began
          else {
            return
          }
          // End the stream as if stopped: what was heard is still finalized.
          self?.wasInterrupted = true
          self?.finish(throwing: nil)
        })
      observers.append(
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) {
          [weak self] _ in
          self?.wasInterrupted = true
          self?.finish(throwing: nil)
        })
    }
  #endif
}
