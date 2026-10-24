import Foundation

/// A word with its time and its place in the transcript's text. Mirrors `TranscriptWord` in `src/types.ts`.
public struct TranscriptWord: Codable, Equatable, Sendable {
  public var text: String
  public var start: Double
  public var end: Double
  /// UTF-16 offsets in `Transcript.text`.
  public var range: [Int]
  public var confidence: Double?
  /// `measured` or `estimated`.
  public var timing: String

  public init(text: String, start: Double, end: Double, range: [Int], confidence: Double?, timing: String) {
    self.text = text
    self.start = start
    self.end = end
    self.range = range
    self.confidence = confidence
    self.timing = timing
  }

  public var json: [String: Any] {
    [
      "text": text,
      "start": start,
      "end": end,
      "range": range,
      "confidence": confidence ?? NSNull(),
      "timing": timing,
    ]
  }

  /// The same word, moved by `offset` UTF-16 code units.
  func shifted(by offset: Int) -> TranscriptWord {
    var word = self
    word.range = [range[0] + offset, range[1] + offset]
    return word
  }
}

/// One recognizer result. Mirrors `TranscriptSegment` in `src/types.ts`.
public struct TranscriptSegment: Codable, Equatable, Sendable {
  public var text: String
  public var start: Double
  public var end: Double
  public var range: [Int]
  public var isFinal: Bool
  public var confidence: Double?
  public var alternatives: [String]
  public var words: [TranscriptWord]
  public var language: String?

  public init(
    text: String, start: Double, end: Double, range: [Int], isFinal: Bool, confidence: Double?,
    alternatives: [String], words: [TranscriptWord], language: String?
  ) {
    self.text = text
    self.start = start
    self.end = end
    self.range = range
    self.isFinal = isFinal
    self.confidence = confidence
    self.alternatives = alternatives
    self.words = words
    self.language = language
  }

  public var json: [String: Any] {
    [
      "text": text,
      "start": start,
      "end": end,
      "range": range,
      "isFinal": isFinal,
      "confidence": confidence ?? NSNull(),
      "alternatives": alternatives,
      "words": words.map(\.json),
      "language": language ?? NSNull(),
    ]
  }

  /// The same segment, placed at `offset` in the transcript's text.
  func placed(at offset: Int) -> TranscriptSegment {
    var segment = self
    let shift = offset - range[0]
    segment.range = [offset, offset + text.utf16.count]
    segment.words = words.map { $0.shifted(by: shift) }
    return segment
  }
}

/// Everything recognized: final segments and maybe a volatile one at the end. Mirrors `Transcript` in `src/types.ts`.
public struct Transcript: Codable, Equatable, Sendable {
  public var locale: String
  public var segments: [TranscriptSegment]
  public var duration: Double?
  public var audioUri: String?

  public init(locale: String, segments: [TranscriptSegment] = [], duration: Double? = nil, audioUri: String? = nil) {
    self.locale = locale
    self.segments = segments
    self.duration = duration
    self.audioUri = audioUri
  }

  public var text: String {
    segments.map(\.text).joined()
  }

  public var words: [TranscriptWord] {
    segments.flatMap(\.words)
  }

  public var json: [String: Any] {
    [
      "text": text,
      "locale": locale,
      "segments": segments.map(\.json),
      "words": words.map(\.json),
      "duration": duration ?? NSNull(),
      "audioUri": audioUri ?? NSNull(),
    ]
  }
}
