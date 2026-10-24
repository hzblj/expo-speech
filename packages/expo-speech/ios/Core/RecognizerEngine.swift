import AVFoundation
import Foundation
import Speech

/// `SFSpeechRecognizer`: the engine before iOS 26, or when `ios.engine` is `recognizer`. One result covers all the
/// audio; it is revised while it runs and final at the end.
public final class RecognizerEngine: SpeechEngine, @unchecked Sendable {
  public let options: TranscriberOptions
  public let recognizer: SFSpeechRecognizer
  public let name = "recognizer"

  public var localeIdentifier: String {
    recognizer.locale.bcp47
  }

  init(options: TranscriberOptions, recognizer: SFSpeechRecognizer) {
    self.options = options
    self.recognizer = recognizer
  }

  public static func make(_ options: TranscriberOptions) throws -> RecognizerEngine {
    let locale = options.locale.map { Locale(identifier: $0) } ?? Locale.current

    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
      throw SpeechFailure(.localeUnavailable, "\(locale.bcp47) is not supported by the speech recognizer")
    }
    if let hint = options.ios.taskHint {
      recognizer.defaultTaskHint = taskHint(hint)
    }
    return RecognizerEngine(options: options, recognizer: recognizer)
  }

  static func taskHint(_ name: String) -> SFSpeechRecognitionTaskHint {
    switch name {
    case "dictation": return .dictation
    case "search": return .search
    case "confirmation": return .confirmation
    default: return .unspecified
    }
  }

  private func checkUsable() throws {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      break
    case .notDetermined:
      throw SpeechFailure(.permissionDenied, "Speech recognition is not allowed yet: call requestPermissionsAsync first")
    default:
      throw SpeechFailure(.permissionDenied, "Speech recognition is not allowed")
    }
    if options.onDevice, !recognizer.supportsOnDeviceRecognition {
      throw SpeechFailure(
        .localeUnavailable,
        "\(localeIdentifier) cannot be recognized on this device; `onDevice: false` uses Apple's servers")
    }
    guard recognizer.isAvailable else {
      throw SpeechFailure(.service, "The speech recognizer is not available right now")
    }
  }

  private func configure(_ request: SFSpeechRecognitionRequest) {
    request.shouldReportPartialResults = options.volatileResults
    request.contextualStrings = options.contextualStrings
    request.requiresOnDeviceRecognition = options.onDevice
    request.taskHint = options.ios.taskHint.map(Self.taskHint) ?? (options.mode == .dictation ? .dictation : .unspecified)
    if #available(iOS 16.0, macOS 13.0, *) {
      request.addsPunctuation = options.punctuation
    }
    if #available(iOS 17.0, macOS 14.0, *), let model = options.ios.customLanguageModel,
      let languageModel = URL(string: model.languageModel)
    {
      request.customizedLanguageModel = SFSpeechLanguageModel.Configuration(
        languageModel: languageModel, vocabulary: model.vocabulary.flatMap { URL(string: $0) })
    }
  }

  public func prepare(download: Bool, sink: EngineSink?) async throws {
    try checkUsable()
  }

  public func run(_ input: EngineInput, sink: EngineSink) async throws {
    try checkUsable()

    switch input {
    case .file(let reader):
      if reader.range.lowerBound <= 0, reader.range.upperBound >= reader.duration {
        let request = SFSpeechURLRecognitionRequest(url: reader.url)
        configure(request)
        try await recognize(request, offset: 0, duration: reader.duration, sink: sink)
      } else {
        // Part of a file: decoded here and appended, with times moved to the file's.
        let request = SFSpeechAudioBufferRecognitionRequest()
        configure(request)
        let chunks = try reader.chunks(in: request.nativeAudioFormat)
        let feeding = Task {
          for try await chunk in chunks {
            request.append(chunk.buffer)
          }
          request.endAudio()
        }
        defer { feeding.cancel() }
        try await recognize(
          request, offset: reader.range.lowerBound,
          duration: reader.range.upperBound - reader.range.lowerBound, sink: sink)
      }
    case .microphone(let capture):
      let request = SFSpeechAudioBufferRecognitionRequest()
      configure(request)
      let stream = try capture.start(format: request.nativeAudioFormat)
      let feeding = Task {
        do {
          for try await chunk in stream {
            request.append(chunk.buffer)
          }
        } catch {}
        request.endAudio()
      }
      defer { feeding.cancel() }
      try await recognize(request, offset: 0, duration: nil, sink: sink)
    }
  }

  private func recognize(
    _ request: SFSpeechRecognitionRequest, offset: Double, duration: Double?, sink: EngineSink
  ) async throws {
    let state = TaskState()
    let alternatives = options.alternatives

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        state.continuation = continuation
        state.task = recognizer.recognitionTask(with: request) { result, error in
          if let result {
            let recognized = Self.recognized(result, offset: offset, alternatives: alternatives)
            sink.engine(recognized: recognized)
            if let duration, duration > 0, result.isFinal || recognized.end > 0 {
              sink.engine(
                progress: result.isFinal ? 1 : min(1, (recognized.end - offset) / duration), phase: "transcribing")
            }
            if result.isFinal {
              state.resume(throwing: nil)
              return
            }
          }
          if let error {
            state.resume(throwing: SpeechFailure.isNoSpeech(error) ? nil : error)
          }
        }
      }
    } onCancel: {
      state.cancel()
    }
  }

  /// A result as runs: the transcription's segments, timed once final, and the text between them.
  static func recognized(_ result: SFSpeechRecognitionResult, offset: Double, alternatives: Bool) -> RecognizedResult {
    let transcription = result.bestTranscription
    let text = transcription.formattedString as NSString
    var runs: [RecognizedRun] = []
    var cursor = 0

    for segment in transcription.segments {
      let range = segment.substringRange
      if range.location > cursor {
        runs.append(RecognizedRun(text: text.substring(with: NSRange(location: cursor, length: range.location - cursor))))
      }
      let timed = segment.duration > 0
      runs.append(
        RecognizedRun(
          text: text.substring(with: range), start: timed ? segment.timestamp + offset : nil,
          end: timed ? segment.timestamp + segment.duration + offset : nil,
          confidence: segment.confidence > 0 ? Double(segment.confidence) : nil))
      cursor = range.location + range.length
    }
    if cursor < text.length {
      runs.append(RecognizedRun(text: text.substring(from: cursor)))
    }

    let timed = runs.filter { $0.start != nil }
    let metadata = result.speechRecognitionMetadata
    let start = timed.first?.start ?? metadata.map { $0.speechStartTimestamp + offset } ?? offset
    let end = timed.last?.end ?? metadata.map { $0.speechStartTimestamp + $0.speechDuration + offset } ?? start

    return RecognizedResult(
      runs: runs, start: start, end: end, isFinal: result.isFinal,
      alternatives: alternatives ? result.transcriptions.dropFirst().map(\.formattedString) : [])
  }
}

/// A recognition task's continuation, resumed once whatever ends it first: the final result, an error or a cancel.
private final class TaskState: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  var continuation: CheckedContinuation<Void, Error>?
  var task: SFSpeechRecognitionTask?

  func resume(throwing error: Error?) {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard !resumed else {
        return nil
      }
      resumed = true
      return self.continuation
    }
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }

  func cancel() {
    task?.cancel()
    resume(throwing: CancellationError())
  }
}
