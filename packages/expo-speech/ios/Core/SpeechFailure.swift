import Foundation
import Speech

/// An error with one of the codes of `SpeechErrorCode` in `src/types.ts`.
public struct SpeechFailure: Error, LocalizedError, Sendable {
  public enum Code: String, Sendable {
    case permissionDenied = "permission-denied"
    case unsupported
    case localeUnavailable = "locale-unavailable"
    case audio
    case network
    case busy
    case interrupted
    case service
    case cancelled
    case startTimeout = "start-timeout"
    case unknown
  }

  public let code: Code
  public let message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }

  public var errorDescription: String? {
    message
  }

  public var json: [String: Any] {
    ["code": code.rawValue, "message": message]
  }

  /// Any error, as a failure with the closest code.
  public static func from(_ error: Error) -> SpeechFailure {
    if let failure = error as? SpeechFailure {
      return failure
    }
    if error is CancellationError {
      return SpeechFailure(.cancelled, "The transcription was cancelled")
    }

    let nsError = error as NSError

    if nsError.domain == NSURLErrorDomain {
      return SpeechFailure(.network, nsError.localizedDescription)
    }
    // `SFSpeechErrorDomain` by name: the constant needs iOS 17. 2 is audioReadFailed, 12 timeout.
    if nsError.domain == "SFSpeechErrorDomain" {
      switch nsError.code {
      case 2:
        return SpeechFailure(.audio, nsError.localizedDescription)
      case 12:
        return SpeechFailure(.network, nsError.localizedDescription)
      default:
        return SpeechFailure(.service, nsError.localizedDescription)
      }
    }
    // The recognizer's own domain: 1101/1110 mean no speech, 203 no match, 301 cancelled, 1700 not authorized.
    if nsError.domain == "kAFAssistantErrorDomain" || nsError.domain == "kLSRErrorDomain" {
      switch nsError.code {
      case 301, 216:
        return SpeechFailure(.cancelled, nsError.localizedDescription)
      case 1700:
        return SpeechFailure(.permissionDenied, nsError.localizedDescription)
      case 1101, 1107, 1110, 203:
        return SpeechFailure(.service, nsError.localizedDescription)
      default:
        return SpeechFailure(.service, nsError.localizedDescription)
      }
    }
    if nsError.domain == AVFoundationErrorDomainName || nsError.domain == NSOSStatusErrorDomain {
      return SpeechFailure(.audio, nsError.localizedDescription)
    }
    return SpeechFailure(.unknown, nsError.localizedDescription)
  }

  /// Whether the error only means the audio had no speech in it: an empty transcript, not a failure.
  static func isNoSpeech(_ error: Error) -> Bool {
    let nsError = error as NSError
    return (nsError.domain == "kAFAssistantErrorDomain" || nsError.domain == "kLSRErrorDomain")
      && [203, 1110].contains(nsError.code)
  }
}

private let AVFoundationErrorDomainName = "AVFoundationErrorDomain"
