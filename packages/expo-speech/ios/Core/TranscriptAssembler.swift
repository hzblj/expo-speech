import Foundation

/// A piece of a result as an engine reports it: some text and, when the engine timed it, its time.
public struct RecognizedRun: Sendable, Equatable {
  public var text: String
  public var start: Double?
  public var end: Double?
  public var confidence: Double?

  public init(text: String, start: Double? = nil, end: Double? = nil, confidence: Double? = nil) {
    self.text = text
    self.start = start
    self.end = end
    self.confidence = confidence
  }
}

/// One result of an engine, before it has a place in the transcript.
public struct RecognizedResult: Sendable, Equatable {
  /// Concatenated, the runs are the result's text.
  public var runs: [RecognizedRun]
  public var start: Double
  public var end: Double
  public var isFinal: Bool
  public var alternatives: [String]
  public var language: String?

  public init(
    runs: [RecognizedRun], start: Double, end: Double, isFinal: Bool, alternatives: [String] = [],
    language: String? = nil
  ) {
    self.runs = runs
    self.start = start
    self.end = end
    self.isFinal = isFinal
    self.alternatives = alternatives
    self.language = language
  }

  public var text: String {
    runs.map(\.text).joined()
  }
}

enum WordBuilder {
  private struct Token {
    var text: String
    var offset: Int
    var length: Int
    var start: Double?
    var end: Double?
    var confidence: Double?
    var measured: Bool
  }

  /// The whitespace-separated tokens of `text`, with their UTF-16 offsets.
  static func tokens(of text: String) -> [(text: String, offset: Int, length: Int)] {
    var tokens: [(text: String, offset: Int, length: Int)] = []
    var current = ""
    var currentOffset = 0
    var offset = 0

    for character in text {
      let length = String(character).utf16.count

      if character.isWhitespace {
        if !current.isEmpty {
          tokens.append((current, currentOffset, current.utf16.count))
          current = ""
        }
      } else {
        if current.isEmpty {
          currentOffset = offset
        }
        current.append(character)
      }
      offset += length
    }
    if !current.isEmpty {
      tokens.append((current, currentOffset, current.utf16.count))
    }
    return tokens
  }

  /// Splits `start…end` between tokens by their length: a longer word takes longer to say.
  private static func distribute(_ tokens: inout [Token], indices: Range<Int>, from start: Double, to end: Double) {
    let total = indices.reduce(0) { $0 + max(1, tokens[$1].length) }
    let span = max(0, end - start)
    var cursor = start

    for index in indices {
      let share = span * Double(max(1, tokens[index].length)) / Double(max(1, total))
      tokens[index].start = cursor
      tokens[index].end = cursor + share
      cursor += share
    }
  }

  /// The words of a result, with ranges relative to its text. Words the engine did not time get estimated times.
  static func words(of result: RecognizedResult) -> [TranscriptWord] {
    var tokens: [Token] = []
    var offset = 0

    for run in result.runs {
      let runTokens = Self.tokens(of: run.text)
      let timed = run.start != nil && run.end != nil

      for token in runTokens {
        tokens.append(
          Token(
            text: token.text, offset: offset + token.offset, length: token.length, start: nil, end: nil,
            confidence: run.confidence, measured: timed && runTokens.count == 1))
      }
      if timed, let start = run.start, let end = run.end, !runTokens.isEmpty {
        distribute(&tokens, indices: (tokens.count - runTokens.count)..<tokens.count, from: start, to: end)
      }
      offset += run.text.utf16.count
    }

    // Untimed stretches take the time between their timed neighbours, or the result's own bounds.
    var index = 0
    while index < tokens.count {
      guard tokens[index].start == nil else {
        index += 1
        continue
      }
      var last = index
      while last + 1 < tokens.count, tokens[last + 1].start == nil {
        last += 1
      }
      let from = index > 0 ? (tokens[index - 1].end ?? result.start) : result.start
      let to = last + 1 < tokens.count ? (tokens[last + 1].start ?? result.end) : result.end
      distribute(&tokens, indices: index..<(last + 1), from: min(from, to), to: max(from, to))
      index = last + 1
    }

    // A token that touches the one before it, with no space between, is part of it: dictation reports the full stop
    // after "heating" as a run of its own.
    var merged: [Token] = []
    for token in tokens {
      if var last = merged.last, last.offset + last.length == token.offset {
        last.text += token.text
        last.length += token.length
        last.start = min(last.start ?? token.start ?? 0, token.start ?? last.start ?? 0)
        last.end = max(last.end ?? token.end ?? 0, token.end ?? last.end ?? 0)
        last.confidence = last.confidence ?? token.confidence
        merged[merged.count - 1] = last
      } else {
        merged.append(token)
      }
    }

    return merged.map {
      TranscriptWord(
        text: $0.text, start: $0.start ?? result.start, end: $0.end ?? result.end,
        range: [$0.offset, $0.offset + $0.length], confidence: $0.confidence,
        timing: $0.measured ? "measured" : "estimated")
    }
  }

  static func segment(of result: RecognizedResult) -> TranscriptSegment {
    let words = words(of: result)
    let confidences = words.compactMap(\.confidence)
    let text = result.text

    return TranscriptSegment(
      text: text, start: result.start, end: max(result.end, result.start), range: [0, text.utf16.count],
      isFinal: result.isFinal,
      confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
      alternatives: result.alternatives, words: words, language: result.language)
  }
}

/// Builds a transcript from an engine's results as they come: final ones are appended for good, the volatile one is
/// replaced every time. Keeps the text offsets of every word right across segments.
public final class TranscriptAssembler {
  private var finals: [TranscriptSegment] = []
  private var finalLength = 0
  private var volatile: TranscriptSegment?
  public let locale: String
  public var duration: Double?
  public var audioUri: String?

  public init(locale: String, finals: [TranscriptSegment] = []) {
    self.locale = locale
    for segment in finals {
      self.finals.append(segment.placed(at: finalLength))
      finalLength += segment.text.utf16.count
    }
  }

  /// The segment for `result`, placed after the final text. A space separates it from that text when neither side
  /// has one: Android's segments come without, Apple's with.
  private func place(_ result: RecognizedResult) -> TranscriptSegment {
    var result = result
    let previous = finals.last?.text ?? ""

    if let last = previous.last, !last.isWhitespace, let first = result.text.first, !first.isWhitespace {
      result.runs.insert(RecognizedRun(text: " "), at: 0)
    }
    return WordBuilder.segment(of: result).placed(at: finalLength)
  }

  /// Appends final results. Returns their segments, placed. Drops the volatile segment they settle.
  @discardableResult
  public func appendFinal(_ results: [RecognizedResult]) -> [TranscriptSegment] {
    var appended: [TranscriptSegment] = []

    for result in results where !result.text.isEmpty {
      var final = result
      final.isFinal = true
      let segment = place(final)
      finals.append(segment)
      finalLength += segment.text.utf16.count
      appended.append(segment)
    }
    // Any final result settles what was volatile, an empty one too: the recognizer took that text back.
    if !results.isEmpty {
      volatile = nil
    }
    return appended
  }

  /// Replaces the volatile segment. Returns it, placed.
  @discardableResult
  public func setVolatile(_ result: RecognizedResult?) -> TranscriptSegment? {
    guard var result, !result.text.isEmpty else {
      volatile = nil
      return nil
    }
    result.isFinal = false
    volatile = place(result)
    return volatile
  }

  /// Settles the volatile segment as final, for an engine that ended without finalizing it.
  @discardableResult
  public func finalizeVolatile() -> [TranscriptSegment] {
    guard let volatile else {
      return []
    }
    var segment = volatile
    segment.isFinal = true
    finals.append(segment)
    finalLength += segment.text.utf16.count
    self.volatile = nil
    return [segment]
  }

  public var currentVolatile: TranscriptSegment? {
    volatile
  }

  /// The final segments only.
  public var finalTranscript: Transcript {
    Transcript(locale: locale, segments: finals, duration: duration, audioUri: audioUri)
  }

  /// Final segments and the volatile one.
  public var transcript: Transcript {
    Transcript(
      locale: locale, segments: volatile.map { finals + [$0] } ?? finals, duration: duration, audioUri: audioUri)
  }

  /// How far the final segments reach into the audio, in seconds.
  public var finalizedThrough: Double {
    finals.last?.end ?? 0
  }
}
