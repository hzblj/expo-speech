package com.hzblj.expospeech

import android.content.Context
import android.content.Intent
import android.os.Build
import android.speech.ModelDownloadListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale

/**
 * Which languages the recognizer has, through `checkRecognitionSupport` (Android 13), and installing them with
 * `triggerModelDownload` (with progress from Android 14). Before Android 13 a recognizer cannot be asked: no lists,
 * and a locale counts as installed when recognition is available at all.
 */
class SpeechLocales(private val context: Context) {
  companion object {
    private val cached = mutableMapOf<Boolean, RecognitionSupport>()
  }

  private fun normalized(tag: String) = Locale.forLanguageTag(tag.replace('_', '-')).toLanguageTag().lowercase()

  private fun createRecognizer(onDevice: Boolean): SpeechRecognizer? = when {
    onDevice && Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context) ->
      SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
    !onDevice && SpeechRecognizer.isRecognitionAvailable(context) -> SpeechRecognizer.createSpeechRecognizer(context)
    else -> null
  }

  private fun intent(locale: String? = null) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
    locale?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
  }

  /** Asked once per process and recognizer kind, and again after an install: each check binds and drops the service. */
  private suspend fun support(onDevice: Boolean, fresh: Boolean = false): RecognitionSupport? {
    if (Build.VERSION.SDK_INT < 33) return null
    if (!fresh) {
      synchronized(cached) { cached[onDevice] }?.let { return it }
    }
    val support = check(onDevice)
    if (support != null) {
      synchronized(cached) { cached[onDevice] = support }
    }
    return support
  }

  private suspend fun check(onDevice: Boolean): RecognitionSupport? {
    return withContext(Dispatchers.Main) {
      val recognizer = createRecognizer(onDevice) ?: return@withContext null
      val result = CompletableDeferred<RecognitionSupport?>()
      try {
        recognizer.checkRecognitionSupport(
          intent(), context.mainExecutor,
          object : RecognitionSupportCallback {
            override fun onSupportResult(recognitionSupport: RecognitionSupport) {
              result.complete(recognitionSupport)
            }

            override fun onError(error: Int) {
              result.complete(null)
            }
          }
        )
        result.await()
      } finally {
        recognizer.destroy()
      }
    }
  }

  suspend fun supported(options: LocaleOptions): List<String> {
    val support = support(options.onDevice) ?: return emptyList()
    val tags = support.installedOnDeviceLanguages + support.pendingOnDeviceLanguages + support.supportedOnDeviceLanguages +
      if (options.onDevice) emptyList() else support.onlineLanguages
    return tags.distinctBy(::normalized).sorted()
  }

  suspend fun installed(options: LocaleOptions): List<String> {
    val support = support(options.onDevice) ?: return emptyList()
    val tags = support.installedOnDeviceLanguages + if (options.onDevice) emptyList() else support.onlineLanguages
    return tags.distinctBy(::normalized).sorted()
  }

  suspend fun status(locale: String, options: LocaleOptions): String {
    if (Build.VERSION.SDK_INT < 33) {
      val available = if (options.onDevice) {
        Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
      } else {
        SpeechRecognizer.isRecognitionAvailable(context)
      }
      return if (available) "installed" else "unsupported"
    }
    val support = support(options.onDevice) ?: return "unsupported"
    val wanted = normalized(locale)
    // A cached answer that says pending or missing may be stale: ask again.
    val current = if (support.installedOnDeviceLanguages.none { normalized(it) == wanted }) {
      support(options.onDevice, fresh = true) ?: support
    } else {
      support
    }
    fun List<String>.has() = any { normalized(it) == wanted }
    return when {
      current.installedOnDeviceLanguages.has() -> "installed"
      !options.onDevice && current.onlineLanguages.has() -> "installed"
      current.pendingOnDeviceLanguages.has() -> "downloading"
      current.supportedOnDeviceLanguages.has() -> "supported"
      else -> "unsupported"
    }
  }

  /** Downloads the locale's on-device model. Android 13 resolves once the download is scheduled. */
  suspend fun install(locale: String, progress: (Double) -> Unit) {
    if (Build.VERSION.SDK_INT < 33) {
      throw SpeechFailure(SpeechFailure.UNSUPPORTED, "Installing a language needs Android 13")
    }
    if (status(locale, LocaleOptions(onDevice = true)) == "installed") {
      progress(1.0)
      return
    }
    withContext(Dispatchers.Main) {
      val recognizer = createRecognizer(onDevice = true)
        ?: throw SpeechFailure(SpeechFailure.UNSUPPORTED, "This device has no on-device speech recognizer")
      try {
        if (Build.VERSION.SDK_INT >= 34) {
          download(recognizer, locale, progress)
        } else {
          recognizer.triggerModelDownload(intent(locale))
        }
      } finally {
        recognizer.destroy()
      }
    }
    synchronized(cached) { cached.clear() }
  }

  @RequiresApi(34)
  private suspend fun download(recognizer: SpeechRecognizer, locale: String, progress: (Double) -> Unit) {
    val done = CompletableDeferred<Unit>()
    recognizer.triggerModelDownload(
      intent(locale), context.mainExecutor,
      object : ModelDownloadListener {
        override fun onProgress(completedPercent: Int) {
          progress(completedPercent / 100.0)
        }

        override fun onSuccess() {
          progress(1.0)
          done.complete(Unit)
        }

        override fun onScheduled() {
          done.complete(Unit)
        }

        override fun onError(error: Int) {
          done.completeExceptionally(
            if (error == SpeechRecognizer.ERROR_CANNOT_LISTEN_TO_DOWNLOAD_EVENTS) {
              SpeechFailure(SpeechFailure.SERVICE, "The download started, but its progress cannot be followed")
            } else {
              SpeechFailure.fromRecognizer(error)
            }
          )
        }
      }
    )
    done.await()
  }
}
