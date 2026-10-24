package com.hzblj.expospeech

import expo.modules.kotlin.AppContext
import expo.modules.kotlin.sharedobjects.SharedObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference

/**
 * A recognizer for one configuration, shared with JavaScript as `SpeechTranscriber`. Owns the queue of file
 * transcriptions: runs up to `maxConcurrent` at once, highest priority first, hands out the transcription already
 * running for a `cacheKey`, and answers from the cache without queueing at all.
 */
class SpeechTranscriberObject(
  appContext: AppContext,
  val options: TranscriberOptions,
  private val storage: SpeechStorage,
  private val downloads: AudioDownloads
) : SharedObject(appContext) {
  private val context = appContext.reactContext ?: throw SpeechFailure(SpeechFailure.UNKNOWN, "There is no React context")
  val engine = AndroidEngine(context, options)
  private val cache = TranscriptCache(storage)
  private val lock = Any()
  private val queue = mutableListOf<Pair<TranscriptionObject, Pair<String, TranscribeOptions>>>()
  private val running = mutableListOf<TranscriptionObject>()
  private var order = 0L

  val locale: String get() = engine.locale
  val pending: Int get() = synchronized(lock) { queue.size + running.size }

  suspend fun prepare(download: Boolean) {
    if (download && options.onDevice) {
      val locales = SpeechLocales(context)
      if (locales.status(locale, LocaleOptions(options.mode, true)) == "supported") {
        locales.install(locale) {}
      }
    }
    // Creating the recognizer once checks that the configuration can run at all.
    withContext(Dispatchers.Main) { engine.check() }
  }

  fun transcribe(uri: String, transcribeOptions: TranscribeOptions): TranscriptionObject {
    val slot = transcribeOptions.cacheKey?.let {
      val range = if (transcribeOptions.rangeStart != null || transcribeOptions.rangeEnd != null) {
        "${transcribeOptions.rangeStart ?: 0}-${transcribeOptions.rangeEnd ?: -1}"
      } else {
        ""
      }
      CacheSlot(it, locale, options.fingerprint + ";" + range)
    }
    val priority = when (transcribeOptions.priority) {
      "high" -> 1
      "low" -> -1
      else -> 0
    }
    val appContext = appContext ?: throw SpeechFailure(SpeechFailure.UNKNOWN, "The app context is gone")

    val transcription = synchronized(lock) {
      slot?.key?.let { key ->
        (running + queue.map { it.first }).firstOrNull { it.cacheKey == key }?.let { return it }
      }
      order += 1
      TranscriptionObject(appContext, "file", locale, slot, priority, order)
    }

    if (slot != null) {
      cache.read(slot.key, slot.locale, slot.fingerprint)?.let {
        transcription.complete(it)
        return transcription
      }
    }

    transcription.onSettled = { settled -> remove(settled) }
    synchronized(lock) {
      queue.add(transcription to (uri to transcribeOptions))
      queue.sortWith(compareByDescending<Pair<TranscriptionObject, *>> { it.first.priority }.thenBy { it.first.order })
    }
    pump()
    return transcription
  }

  private fun pump() {
    while (true) {
      val next = synchronized(lock) {
        if (running.size >= options.maxConcurrent || queue.isEmpty()) {
          null
        } else {
          queue.removeAt(0).also { running.add(it.first) }
        }
      } ?: return
      val (transcription, source) = next
      transcription.runFile(source.first, source.second, engine, downloads, cache)
    }
  }

  private fun remove(transcription: TranscriptionObject) {
    synchronized(lock) {
      queue.removeAll { it.first === transcription }
      running.remove(transcription)
    }
    pump()
  }

  fun listen(listenOptions: ListenOptions): TranscriptionObject {
    val appContext = appContext ?: throw SpeechFailure(SpeechFailure.UNKNOWN, "The app context is gone")
    val transcription = synchronized(Microphone) {
      Microphone.current?.get()?.takeIf { !it.isSettled }?.let {
        throw SpeechFailure(SpeechFailure.BUSY, "The microphone is already being transcribed")
      }
      TranscriptionObject(appContext, "microphone", locale, null, 0, 0).also {
        Microphone.current = WeakReference(it)
      }
    }
    transcription.runMicrophone(listenOptions, engine, storage.recordings)
    return transcription
  }

  fun cancelAll() {
    val all = synchronized(lock) { queue.map { it.first } + running }
    all.forEach { it.cancel() }
  }

  override fun sharedObjectDidRelease() {
    cancelAll()
  }

  /** The microphone is one: a second `listen` anywhere in the app is refused while one runs. */
  private object Microphone {
    var current: WeakReference<TranscriptionObject>? = null
  }
}
