package com.hzblj.expospeech

import org.json.JSONArray
import org.json.JSONObject

/** A word with its time and its place in the transcript's text. Mirrors `TranscriptWord` in `src/types.ts`. */
data class TranscriptWord(
  val text: String,
  val start: Double,
  val end: Double,
  /** UTF-16 offsets in the transcript's text: Kotlin's own string indices. */
  val range: IntRange,
  val confidence: Double?,
  /** `measured` or `estimated`. */
  val timing: String
) {
  fun toMap(): Map<String, Any?> = mapOf(
    "text" to text,
    "start" to start,
    "end" to end,
    "range" to listOf(range.first, range.last + 1),
    "confidence" to confidence,
    "timing" to timing
  )

  fun shifted(by: Int) = copy(range = (range.first + by)..(range.last + by))

  fun toJson(): JSONObject = JSONObject()
    .put("text", text)
    .put("start", start)
    .put("end", end)
    .put("range", JSONArray(listOf(range.first, range.last + 1)))
    .put("confidence", confidence ?: JSONObject.NULL)
    .put("timing", timing)

  companion object {
    fun fromJson(json: JSONObject): TranscriptWord {
      val range = json.getJSONArray("range")
      return TranscriptWord(
        text = json.getString("text"),
        start = json.getDouble("start"),
        end = json.getDouble("end"),
        range = range.getInt(0) until range.getInt(1),
        confidence = if (json.isNull("confidence")) null else json.getDouble("confidence"),
        timing = json.getString("timing")
      )
    }
  }
}

/** One recognizer result. Mirrors `TranscriptSegment` in `src/types.ts`. */
data class TranscriptSegment(
  val text: String,
  val start: Double,
  val end: Double,
  val range: IntRange,
  val isFinal: Boolean,
  val confidence: Double?,
  val alternatives: List<String>,
  val words: List<TranscriptWord>,
  val language: String?
) {
  fun toMap(): Map<String, Any?> = mapOf(
    "text" to text,
    "start" to start,
    "end" to end,
    "range" to listOf(range.first, range.last + 1),
    "isFinal" to isFinal,
    "confidence" to confidence,
    "alternatives" to alternatives,
    "words" to words.map { it.toMap() },
    "language" to language
  )

  /** The same segment, placed at `offset` in the transcript's text. */
  fun placed(at: Int): TranscriptSegment {
    val shift = at - range.first
    return copy(range = at until at + text.length, words = words.map { it.shifted(shift) })
  }

  fun toJson(): JSONObject = JSONObject()
    .put("text", text)
    .put("start", start)
    .put("end", end)
    .put("range", JSONArray(listOf(range.first, range.last + 1)))
    .put("isFinal", isFinal)
    .put("confidence", confidence ?: JSONObject.NULL)
    .put("alternatives", JSONArray(alternatives))
    .put("words", JSONArray(words.map { it.toJson() }))
    .put("language", language ?: JSONObject.NULL)

  companion object {
    fun fromJson(json: JSONObject): TranscriptSegment {
      val range = json.getJSONArray("range")
      val alternatives = json.getJSONArray("alternatives")
      val words = json.getJSONArray("words")
      return TranscriptSegment(
        text = json.getString("text"),
        start = json.getDouble("start"),
        end = json.getDouble("end"),
        range = range.getInt(0) until range.getInt(1),
        isFinal = json.getBoolean("isFinal"),
        confidence = if (json.isNull("confidence")) null else json.getDouble("confidence"),
        alternatives = (0 until alternatives.length()).map { alternatives.getString(it) },
        words = (0 until words.length()).map { TranscriptWord.fromJson(words.getJSONObject(it)) },
        language = if (json.isNull("language")) null else json.getString("language")
      )
    }
  }
}

/** Final segments and maybe a volatile one at the end. Mirrors `Transcript` in `src/types.ts`. */
data class Transcript(
  val locale: String,
  val segments: List<TranscriptSegment> = emptyList(),
  val duration: Double? = null,
  val audioUri: String? = null
) {
  val text: String get() = segments.joinToString("") { it.text }
  val words: List<TranscriptWord> get() = segments.flatMap { it.words }

  fun toMap(): Map<String, Any?> = mapOf(
    "text" to text,
    "locale" to locale,
    "segments" to segments.map { it.toMap() },
    "words" to words.map { it.toMap() },
    "duration" to duration,
    "audioUri" to audioUri
  )

  fun toJson(): JSONObject = JSONObject()
    .put("locale", locale)
    .put("segments", JSONArray(segments.map { it.toJson() }))
    .put("duration", duration ?: JSONObject.NULL)
    .put("audioUri", audioUri ?: JSONObject.NULL)

  companion object {
    fun fromJson(json: JSONObject): Transcript {
      val segments = json.getJSONArray("segments")
      return Transcript(
        locale = json.getString("locale"),
        segments = (0 until segments.length()).map { TranscriptSegment.fromJson(segments.getJSONObject(it)) },
        duration = if (json.isNull("duration")) null else json.getDouble("duration"),
        audioUri = if (json.isNull("audioUri")) null else json.getString("audioUri")
      )
    }
  }
}
