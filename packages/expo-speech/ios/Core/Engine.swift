import AVFoundation
import Foundation

/// What an engine reports while it runs. Called from any thread.
public protocol EngineSink: AnyObject, Sendable {
  /// A final result, or the new volatile one (`isFinal == false`).
  func engine(recognized result: RecognizedResult)
  func engine(detectedSpeech detected: Bool, at time: Double)
  /// Phases are those of the `progress` event: `installing`, `downloading`, `transcribing`.
  func engine(progress fraction: Double, phase: String)
}

/// Where the audio comes from.
public enum EngineInput: @unchecked Sendable {
  case file(AudioFileReader)
  case microphone(MicrophoneCapture)
}

/// A way of turning audio into results: `SpeechAnalyzer` (iOS 26) or `SFSpeechRecognizer`.
public protocol SpeechEngine: AnyObject, Sendable {
  /// The locale actually used, as a BCP 47 tag.
  var localeIdentifier: String { get }
  /// `analyzer` or `recognizer`.
  var name: String { get }
  /// Loads the model, downloading it first when `download` is set and it is missing.
  func prepare(download: Bool, sink: EngineSink?) async throws
  /// Runs until the input ends: the end of the file, or the microphone stopped.
  func run(_ input: EngineInput, sink: EngineSink) async throws
}

extension Locale {
  /// `en-GB` rather than `en_GB`.
  var bcp47: String {
    identifier(.bcp47)
  }
}

/// Picks the engine for these options: the analyzer on iOS 26 and later unless `ios.engine` says otherwise.
public enum SpeechEngines {
  public static var analyzerAvailable: Bool {
    if #available(iOS 26.0, macOS 26.0, *) {
      return true
    }
    return false
  }

  public static func make(_ options: TranscriberOptions) async throws -> SpeechEngine {
    let useAnalyzer: Bool

    switch options.ios.engine {
    case .analyzer:
      guard analyzerAvailable else {
        throw SpeechFailure(.unsupported, "SpeechAnalyzer needs iOS 26")
      }
      useAnalyzer = true
    case .recognizer:
      useAnalyzer = false
    case .auto:
      useAnalyzer = analyzerAvailable
    }

    if useAnalyzer, #available(iOS 26.0, macOS 26.0, *) {
      // An analyzer asked for by name gets no fallback.
      if options.onDevice == .preferred, options.ios.engine == .auto {
        return try await PreferredEngine.make(options)
      }
      return try await AnalyzerEngine.make(options)
    }
    return try RecognizerEngine.make(options)
  }
}
