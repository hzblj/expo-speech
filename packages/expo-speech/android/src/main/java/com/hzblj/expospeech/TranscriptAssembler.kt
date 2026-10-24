package com.hzblj.expospeech

/** A piece of a result as the recognizer reports it: some text and, when it was timed, its time. */
data class RecognizedRun(
  val text: String,
  val start: Double? = null,
  val end: Double? = null,
  val confidence: Double? = null
)

/** One result of the recognizer, before it has a place in the transcript. */
data class RecognizedResult(
  /** Concatenated, the runs are the result's text. */
  val runs: List<RecognizedRun>,
  val start: Double,
  val end: Double,
  val isFinal: Boolean,
  val alternatives: List<String> = emptyList(),
  val language: String? = null
) {
  val text: String get() = runs.joinToString("") { it.text }
}

/** The same rules as `WordBuilder` in `ios/Core/TranscriptAssembler.swift`: keep the two in step. */
internal object WordBuilder {
  private class Token(
    var text: String,
    val offset: Int,
    var start: Double? = null,
    var end: Double? = null,
    var confidence: Double?,
    val measured: Boolean
  )

  /** The whitespace-separated tokens of `text`, with their offsets. */
  fun tokens(text: String): List<Pair<String, Int>> {
    val tokens = mutableListOf<Pair<String, Int>>()
    var start = -1

    for (index in text.indices) {
      if (Character.isWhitespace(text[index])) {
        if (start >= 0) {
          tokens.add(text.substring(start, index) to start)
          start = -1
        }
      } else if (start < 0) {
        start = index
      }
    }
    if (start >= 0) {
      tokens.add(text.substring(start) to start)
    }
    return tokens
  }

  /** Splits `from..to` between tokens by their length: a longer word takes longer to say. */
  private fun distribute(tokens: List<Token>, indices: IntRange, from: Double, to: Double) {
    val total = indices.sumOf { maxOf(1, tokens[it].text.length) }
    val span = maxOf(0.0, to - from)
    var cursor = from

    for (index in indices) {
      val share = span * maxOf(1, tokens[index].text.length) / maxOf(1, total)
      tokens[index].start = cursor
      tokens[index].end = cursor + share
      cursor += share
    }
  }

  fun words(result: RecognizedResult): List<TranscriptWord> {
    val tokens = mutableListOf<Token>()
    var offset = 0

    for (run in result.runs) {
      val runTokens = tokens(run.text)
      val timed = run.start != null && run.end != null

      for ((text, at) in runTokens) {
        tokens.add(Token(text, offset + at, confidence = run.confidence, measured = timed && runTokens.size == 1))
      }
      if (timed && runTokens.isNotEmpty()) {
        distribute(tokens, (tokens.size - runTokens.size) until tokens.size, run.start!!, run.end!!)
      }
      offset += run.text.length
    }

    // Untimed stretches take the time between their timed neighbours, or the result's own bounds.
    var index = 0
    while (index < tokens.size) {
      if (tokens[index].start != null) {
        index += 1
        continue
      }
      var last = index
      while (last + 1 < tokens.size && tokens[last + 1].start == null) {
        last += 1
      }
      val from = if (index > 0) tokens[index - 1].end ?: result.start else result.start
      val to = if (last + 1 < tokens.size) tokens[last + 1].start ?: result.end else result.end
      distribute(tokens, index..last, minOf(from, to), maxOf(from, to))
      index = last + 1
    }

    // A token that touches the one before it, with no space between, is part of it: punctuation can come as a part
    // of its own.
    val merged = mutableListOf<Token>()
    for (token in tokens) {
      val last = merged.lastOrNull()
      if (last != null && last.offset + last.text.length == token.offset) {
        last.text += token.text
        last.start = minOf(last.start ?: token.start ?: 0.0, token.start ?: last.start ?: 0.0)
        last.end = maxOf(last.end ?: token.end ?: 0.0, token.end ?: last.end ?: 0.0)
        last.confidence = last.confidence ?: token.confidence
      } else {
        merged.add(token)
      }
    }

    return merged.map {
      TranscriptWord(
        text = it.text,
        start = it.start ?: result.start,
        end = it.end ?: result.end,
        range = it.offset until it.offset + it.text.length,
        confidence = it.confidence,
        timing = if (it.measured) "measured" else "estimated"
      )
    }
  }

  fun segment(result: RecognizedResult): TranscriptSegment {
    val words = words(result)
    val confidences = words.mapNotNull { it.confidence }
    val text = result.text

    return TranscriptSegment(
      text = text,
      start = result.start,
      end = maxOf(result.end, result.start),
      range = 0 until text.length,
      isFinal = result.isFinal,
      confidence = if (confidences.isEmpty()) null else confidences.average(),
      alternatives = result.alternatives,
      words = words,
      language = result.language
    )
  }
}

/**
 * Builds a transcript from results as they come: final ones are appended for good, the volatile one is replaced every
 * time. Keeps every word's text offsets right across segments. Not thread-safe: the transcription guards it.
 */
class TranscriptAssembler(val locale: String, finals: List<TranscriptSegment> = emptyList()) {
  private val finals = mutableListOf<TranscriptSegment>()
  private var finalLength = 0
  var currentVolatile: TranscriptSegment? = null
    private set
  var duration: Double? = null
  var audioUri: String? = null

  init {
    for (segment in finals) {
      this.finals.add(segment.placed(finalLength))
      finalLength += segment.text.length
    }
  }

  /** A space separates a segment from the text before it when neither side has one: Android's segments come without. */
  private fun place(result: RecognizedResult): TranscriptSegment {
    val previous = finals.lastOrNull()?.text ?: ""
    val text = result.text
    val spaced = if (previous.isNotEmpty() && !Character.isWhitespace(previous.last()) && text.isNotEmpty() && !Character.isWhitespace(text.first())) {
      result.copy(runs = listOf(RecognizedRun(" ")) + result.runs)
    } else {
      result
    }
    return WordBuilder.segment(spaced).placed(finalLength)
  }

  fun appendFinal(results: List<RecognizedResult>): List<TranscriptSegment> {
    val appended = mutableListOf<TranscriptSegment>()

    for (result in results) {
      if (result.text.isEmpty()) {
        continue
      }
      val segment = place(result.copy(isFinal = true))
      finals.add(segment)
      finalLength += segment.text.length
      appended.add(segment)
    }
    if (appended.isNotEmpty()) {
      currentVolatile = null
    }
    return appended
  }

  fun setVolatile(result: RecognizedResult?): TranscriptSegment? {
    currentVolatile = if (result == null || result.text.isEmpty()) null else place(result.copy(isFinal = false))
    return currentVolatile
  }

  /** Settles the volatile segment as final, for a recognizer that ended without finalizing it. */
  fun finalizeVolatile(): List<TranscriptSegment> {
    val volatile = currentVolatile ?: return emptyList()
    val segment = volatile.copy(isFinal = true)
    finals.add(segment)
    finalLength += segment.text.length
    currentVolatile = null
    return listOf(segment)
  }

  val finalTranscript: Transcript get() = Transcript(locale, finals.toList(), duration, audioUri)

  val transcript: Transcript
    get() = Transcript(locale, currentVolatile?.let { finals + it } ?: finals.toList(), duration, audioUri)

  /** How far the final segments reach into the audio, in seconds. */
  val finalizedThrough: Double get() = finals.lastOrNull()?.end ?: 0.0
}
