package com.hzblj.expospeech

import android.speech.SpeechRecognizer
import expo.modules.kotlin.exception.CodedException

/** An error with one of the codes of `SpeechErrorCode` in `src/types.ts`; a JavaScript error with that `code`. */
class SpeechFailure(
  val reason: String,
  message: String,
  cause: Throwable? = null,
  /** The recognition service went away before the session started: a new session may well work. */
  val retryable: Boolean = false
) : CodedException(reason, message, cause) {

  fun toMap(): Map<String, Any?> = mapOf("code" to reason, "message" to (message ?: reason))

  companion object {
    const val PERMISSION_DENIED = "permission-denied"
    const val UNSUPPORTED = "unsupported"
    const val LOCALE_UNAVAILABLE = "locale-unavailable"
    const val AUDIO = "audio"
    const val NETWORK = "network"
    const val BUSY = "busy"
    const val INTERRUPTED = "interrupted"
    const val SERVICE = "service"
    const val CANCELLED = "cancelled"
    const val UNKNOWN = "unknown"

    fun from(error: Throwable): SpeechFailure = when (error) {
      is SpeechFailure -> error
      is kotlinx.coroutines.CancellationException -> SpeechFailure(CANCELLED, "The transcription was cancelled", error)
      is java.io.IOException -> SpeechFailure(AUDIO, error.message ?: "The audio could not be read", error)
      else -> SpeechFailure(UNKNOWN, error.message ?: error.toString(), error)
    }

    /** A `SpeechRecognizer.ERROR_*` as a failure. */
    fun fromRecognizer(error: Int): SpeechFailure = when (error) {
      SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
        SpeechFailure(PERMISSION_DENIED, "The recognizer was not allowed to use the microphone")
      SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
        SpeechFailure(NETWORK, "The recognizer could not reach its server (error $error)")
      SpeechRecognizer.ERROR_AUDIO -> SpeechFailure(AUDIO, "The recognizer could not read the audio")
      SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_TOO_MANY_REQUESTS ->
        SpeechFailure(BUSY, "The recognizer is busy (error $error)")
      SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ->
        SpeechFailure(LOCALE_UNAVAILABLE, "The recognizer does not support this language")
      SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
        SpeechFailure(LOCALE_UNAVAILABLE, "The language's model is not installed on this device")
      SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> SpeechFailure(SERVICE, "The recognition service disconnected")
      SpeechRecognizer.ERROR_CLIENT -> SpeechFailure(SERVICE, "The recognizer was used wrongly (ERROR_CLIENT)")
      else -> SpeechFailure(SERVICE, "The recognizer failed (error $error)")
    }

    /** Errors that only mean there was no speech in the audio: an empty transcript, not a failure. */
    fun isNoSpeech(error: Int) = error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
  }
}
