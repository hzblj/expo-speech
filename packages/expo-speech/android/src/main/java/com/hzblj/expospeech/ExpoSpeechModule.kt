package com.hzblj.expospeech

import android.Manifest
import android.os.Build
import android.speech.SpeechRecognizer
import expo.modules.interfaces.permissions.PermissionsResponse
import expo.modules.interfaces.permissions.PermissionsResponseListener
import expo.modules.interfaces.permissions.PermissionsStatus
import expo.modules.kotlin.Promise
import expo.modules.kotlin.functions.Coroutine
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.CompletableDeferred

class ExpoSpeechModule : Module() {
  private val context
    get() = appContext.reactContext ?: throw SpeechFailure(SpeechFailure.UNKNOWN, "There is no React context")

  private val storage by lazy { SpeechStorage(context) }
  private val downloads by lazy { AudioDownloads(context, storage) }
  private val locales by lazy { SpeechLocales(context) }

  private fun status(value: PermissionsStatus?) = when (value) {
    PermissionsStatus.GRANTED -> "granted"
    PermissionsStatus.DENIED -> "denied"
    else -> "undetermined"
  }

  /** Android has no speech recognition permission: only the microphone's, which `microphone` asks about. */
  private fun response(microphone: Boolean, result: Map<String, PermissionsResponse>?): Map<String, Any?> {
    val mic = result?.get(Manifest.permission.RECORD_AUDIO)
    val micStatus = status(mic?.status)
    val status = if (microphone) micStatus else "granted"

    return mapOf(
      "status" to status,
      "granted" to (status == "granted"),
      "canAskAgain" to (if (microphone) mic?.canAskAgain ?: true else true),
      "expires" to "never",
      "speechRecognition" to "granted",
      "microphone" to micStatus
    )
  }

  private suspend fun permissions(microphone: Boolean, ask: Boolean): Map<String, Any?> {
    val manager = appContext.permissions ?: return response(microphone, null)
    val result = CompletableDeferred<Map<String, PermissionsResponse>>()
    val listener = PermissionsResponseListener { result.complete(it) }
    if (ask && microphone) {
      manager.askForPermissions(listener, Manifest.permission.RECORD_AUDIO)
    } else {
      manager.getPermissions(listener, Manifest.permission.RECORD_AUDIO)
    }
    return response(microphone, result.await())
  }

  override fun definition() = ModuleDefinition {
    Name("ExpoSpeech")

    Events("installProgress")

    // The second argument is iOS's speech recognition, which Android has no permission for.
    AsyncFunction("getPermissionsAsync") Coroutine { microphone: Boolean, _: Boolean? ->
      permissions(microphone, ask = false)
    }

    AsyncFunction("requestPermissionsAsync") Coroutine { microphone: Boolean, _: Boolean? ->
      permissions(microphone, ask = true)
    }

    AsyncFunction("getAvailabilityAsync") { _: Map<String, Any?> ->
      val sdk = Build.VERSION.SDK_INT
      mapOf(
        "engine" to "android",
        "available" to SpeechRecognizer.isRecognitionAvailable(context),
        "transcriber" to false,
        "dictation" to false,
        "onDevice" to (sdk >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)),
        "fileTranscription" to (sdk >= 33),
        "wordTiming" to (sdk >= 34),
        "languageDetection" to (sdk >= 34)
      )
    }

    AsyncFunction("getSupportedLocalesAsync") Coroutine { options: Map<String, Any?> ->
      locales.supported(LocaleOptions.from(options))
    }

    AsyncFunction("getInstalledLocalesAsync") Coroutine { options: Map<String, Any?> ->
      locales.installed(LocaleOptions.from(options))
    }

    AsyncFunction("getLocaleStatusAsync") Coroutine { locale: String, options: Map<String, Any?> ->
      locales.status(locale, LocaleOptions.from(options))
    }

    AsyncFunction("installLocaleAsync") Coroutine { locale: String, options: Map<String, Any?> ->
      val mode = LocaleOptions.from(options).mode
      locales.install(locale) { fraction ->
        sendEvent("installProgress", mapOf("locale" to locale, "mode" to mode, "fraction" to fraction))
      }
    }

    // iOS's AssetInventory has no Android counterpart: nothing is reserved, nothing is retained.
    AsyncFunction("getReservedLocalesAsync") { emptyList<String>() }
    AsyncFunction("reserveLocaleAsync") { _: String -> false }
    AsyncFunction("releaseLocaleAsync") { _: String -> false }
    Constant("maximumReservedLocales") { 0 }
    AsyncFunction("endModelRetentionAsync") {}
    AsyncFunction("prepareCustomLanguageModelAsync") { _: Map<String, Any?> -> null }

    AsyncFunction("clearCacheAsync") { options: Map<String, Any?> ->
      storage.clear(transcripts = options["transcripts"] as? Boolean ?: true, audio = options["audio"] as? Boolean ?: true)
    }

    Class("SpeechTranscriber", SpeechTranscriberObject::class) {
      Constructor { options: Map<String, Any?>? ->
        SpeechTranscriberObject(appContext, TranscriberOptions.from(options), storage, downloads)
      }

      Property("locale") { transcriber: SpeechTranscriberObject -> transcriber.locale }
      Property("engine") { _: SpeechTranscriberObject -> "android" }
      Property("pending") { transcriber: SpeechTranscriberObject -> transcriber.pending }

      AsyncFunction("prepareAsync") Coroutine { transcriber: SpeechTranscriberObject, options: Map<String, Any?>? ->
        transcriber.prepare(download = options?.get("download") as? Boolean ?: false)
      }

      Function("transcribeUri") { transcriber: SpeechTranscriberObject, uri: String, options: Map<String, Any?>? ->
        transcriber.transcribe(uri, TranscribeOptions.from(options))
      }

      Function("listen") { transcriber: SpeechTranscriberObject, options: Map<String, Any?>? ->
        val manager = appContext.permissions
        if (manager != null && !manager.hasGrantedPermissions(Manifest.permission.RECORD_AUDIO)) {
          throw SpeechFailure(SpeechFailure.PERMISSION_DENIED, "The microphone is not allowed: call requestPermissionsAsync first")
        }
        transcriber.listen(ListenOptions.from(options))
      }

      Function("cancelAll") { transcriber: SpeechTranscriberObject -> transcriber.cancelAll() }
    }

    Class("Transcription", TranscriptionObject::class) {
      // Required of a shared object class here; transcriptions only come from a transcriber.
      Constructor { ->
        throw SpeechFailure(SpeechFailure.UNSUPPORTED, "A Transcription comes from SpeechTranscriber.transcribe or listen")
      }

      Property("id") { transcription: TranscriptionObject -> transcription.id }
      Property("kind") { transcription: TranscriptionObject -> transcription.kind }
      Property("state") { transcription: TranscriptionObject -> transcription.state }
      Property("cacheKey") { transcription: TranscriptionObject -> transcription.cacheKey }
      Property("fromCache") { transcription: TranscriptionObject -> transcription.fromCache }
      Property("progress") { transcription: TranscriptionObject -> transcription.progress }
      Property("transcript") { transcription: TranscriptionObject -> transcription.transcript.toMap() }
      Property("error") { transcription: TranscriptionObject -> transcription.failure?.toMap() }

      AsyncFunction("wait") { transcription: TranscriptionObject, promise: Promise ->
        transcription.wait(promise)
      }

      Function("stop") { transcription: TranscriptionObject -> transcription.stop() }
      Function("cancel") { transcription: TranscriptionObject -> transcription.cancel() }
    }
  }
}
