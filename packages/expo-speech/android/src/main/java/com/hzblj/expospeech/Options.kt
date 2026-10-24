package com.hzblj.expospeech

import java.util.Locale

@Suppress("UNCHECKED_CAST")
private fun Map<String, Any?>.map(key: String): Map<String, Any?>? = this[key] as? Map<String, Any?>
private fun Map<String, Any?>.string(key: String): String? = this[key] as? String
private fun Map<String, Any?>.bool(key: String): Boolean? = this[key] as? Boolean
private fun Map<String, Any?>.number(key: String): Double? = (this[key] as? Number)?.toDouble()
private fun Map<String, Any?>.strings(key: String): List<String> = (this[key] as? List<*>)?.filterIsInstance<String>() ?: emptyList()

/** `SpeechTranscriberOptions` from `src/types.ts`, read from the object JavaScript passes. Defaults are the documented ones. */
data class TranscriberOptions(
  val locale: String?,
  val mode: String = "transcription",
  val onDevice: Boolean = true,
  val contextualStrings: List<String> = emptyList(),
  val punctuation: Boolean = true,
  val volatileResults: Boolean = true,
  val alternatives: Boolean = false,
  val maskOffensiveWords: Boolean? = null,
  /** `null` when off, otherwise the sensitivity. */
  val detectSpeech: String? = null,
  val maxConcurrent: Int = 1,
  val android: Android = Android()
) {
  data class Android(
    val recognitionService: String? = null,
    val formatting: String? = null,
    val hidePartialTrailingPunctuation: Boolean? = null,
    val biasingDeviceContext: Boolean? = null,
    val languageDetection: Boolean = false,
    val languageDetectionAllowed: List<String> = emptyList(),
    val languageSwitch: String? = null,
    val languageSwitchAllowed: List<String> = emptyList(),
    val languageSwitchMaxSwitches: Int? = null,
    val languageSwitchInitialActiveMillis: Int? = null,
    val preferOffline: Boolean? = null,
    val maxResults: Int? = null,
    val extras: Map<String, Any?> = emptyMap(),
    /** How many times faster than real time a file is fed to the recognizer. */
    val feedSpeed: Double = 4.0
  )

  /** The locale as a BCP 47 tag: the requested one, or the device's. */
  val localeTag: String get() = locale ?: Locale.getDefault().toLanguageTag()

  /** What a cached transcript depends on, besides the audio and the locale. */
  val fingerprint: String
    get() = listOf(
      mode, if (punctuation) "p" else "", if (alternatives) "a" else "", if (maskOffensiveWords == true) "m" else "",
      if (onDevice) "d" else "", contextualStrings.joinToString("|"), android.recognitionService ?: "",
      android.formatting ?: "", android.maxResults?.toString() ?: "",
      if (android.languageDetection) "l" + android.languageDetectionAllowed.joinToString(",") else "",
      android.languageSwitch?.let { it + android.languageSwitchAllowed.joinToString(",") } ?: "",
      android.extras.toSortedMap().toString()
    ).joinToString(";")

  companion object {
    fun from(map: Map<String, Any?>?): TranscriberOptions {
      val options = map ?: emptyMap()
      val android = options.map("android") ?: emptyMap()
      val detection = android["languageDetection"]
      val switch = android.map("languageSwitch")
      val detectSpeech = when (val value = options["detectSpeech"]) {
        is String -> value
        true -> "medium"
        else -> null
      }

      return TranscriberOptions(
        locale = options.string("locale"),
        mode = options.string("mode") ?: "transcription",
        onDevice = options.bool("onDevice") ?: true,
        contextualStrings = options.strings("contextualStrings"),
        punctuation = options.bool("punctuation") ?: true,
        volatileResults = options.bool("volatileResults") ?: true,
        alternatives = options.bool("alternatives") ?: false,
        maskOffensiveWords = options.bool("maskOffensiveWords"),
        detectSpeech = detectSpeech,
        maxConcurrent = maxOf(1, options.number("maxConcurrent")?.toInt() ?: 1),
        android = Android(
          recognitionService = android.string("recognitionService"),
          formatting = android.string("formatting"),
          hidePartialTrailingPunctuation = android.bool("hidePartialTrailingPunctuation"),
          biasingDeviceContext = android.bool("biasingDeviceContext"),
          languageDetection = detection == true || detection is Map<*, *>,
          languageDetectionAllowed = (detection as? Map<*, *>)?.get("allowedLanguages")?.let { list ->
            (list as? List<*>)?.filterIsInstance<String>()
          } ?: emptyList(),
          languageSwitch = switch?.let { it.string("mode") ?: "balanced" },
          languageSwitchAllowed = switch?.strings("allowedLanguages") ?: emptyList(),
          languageSwitchMaxSwitches = switch?.number("maxSwitches")?.toInt(),
          languageSwitchInitialActiveMillis = switch?.number("initialActiveDurationMillis")?.toInt(),
          preferOffline = android.bool("preferOffline"),
          maxResults = android.number("maxResults")?.toInt(),
          extras = android.map("extras") ?: emptyMap(),
          feedSpeed = android.number("feedSpeed")?.takeIf { it > 0 } ?: 4.0
        )
      )
    }
  }
}

/** `TranscribeOptions` from `src/types.ts`. */
data class TranscribeOptions(
  val cacheKey: String? = null,
  val priority: String = "normal",
  val rangeStart: Double? = null,
  val rangeEnd: Double? = null,
  val headers: Map<String, String> = emptyMap()
) {
  companion object {
    fun from(map: Map<String, Any?>?): TranscribeOptions {
      val options = map ?: emptyMap()
      val range = options.map("range")
      return TranscribeOptions(
        cacheKey = options.string("cacheKey"),
        priority = options.string("priority") ?: "normal",
        rangeStart = range?.number("start"),
        rangeEnd = range?.number("end"),
        headers = options.map("headers")?.mapNotNull { (key, value) -> (value as? String)?.let { key to it } }?.toMap()
          ?: emptyMap()
      )
    }
  }
}

/** `ListenOptions` from `src/types.ts`. */
data class ListenOptions(
  val record: Boolean = false,
  val volumeIntervalMillis: Long = 0,
  val silenceMillis: Long? = null
) {
  companion object {
    fun from(map: Map<String, Any?>?): ListenOptions {
      val options = map ?: emptyMap()
      return ListenOptions(
        record = options.bool("record") ?: false,
        volumeIntervalMillis = options.number("volumeInterval")?.toLong() ?: 0,
        silenceMillis = options.map("android")?.number("silenceMillis")?.toLong()
      )
    }
  }
}

/** `LocaleOptions` from `src/types.ts`. */
data class LocaleOptions(val mode: String = "transcription", val onDevice: Boolean = true) {
  companion object {
    fun from(map: Map<String, Any?>?) = LocaleOptions(
      mode = map?.string("mode") ?: "transcription",
      onDevice = map?.bool("onDevice") ?: true
    )
  }
}
