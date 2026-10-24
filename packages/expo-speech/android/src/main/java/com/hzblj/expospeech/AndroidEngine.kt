package com.hzblj.expospeech

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognitionPart
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/** What the engine reports while it runs. Called from any thread. */
interface EngineSink {
  /** A final result, or the new volatile one (`isFinal == false`). */
  fun recognized(result: RecognizedResult)
  fun speech(detected: Boolean, time: Double)
  /** Phases are those of the `progress` event: `downloading`, `transcribing`. */
  fun progress(fraction: Double, phase: String)
  fun volume(level: Double)
  fun language(locale: String, confidence: String, switchResult: String?)
}

/** Where a session's audio comes from. */
sealed interface EngineAudio {
  /**
   * PCM (16 kHz, mono, 16-bit) pushed by `feed`, which returns when the audio ends: a decoded file, or the microphone
   * through `AudioRecord`. Goes to the recognizer through `EXTRA_AUDIO_SOURCE`, Android 13 and later.
   */
  class Stream(
    val feed: suspend (write: (ShortArray) -> Unit) -> Unit,
    /** Seconds of the file before the stream, added to every time. */
    val offset: Double = 0.0,
    /** The stream's length in seconds, for progress. */
    val duration: Double? = null
  ) : EngineAudio

  /** The recognizer's own microphone, before Android 13: one utterance at a time, restarted until `stop`. */
  class RecognizerMicrophone(val stopped: CompletableDeferred<Unit>) : EngineAudio
}

/**
 * `android.speech.SpeechRecognizer`: the on-device recognizer (Android 12), or the default one, or a named service.
 * Files and the microphone both go through `EXTRA_AUDIO_SOURCE` in a segmented session (Android 13), which ends when
 * the audio does, with each segment's words timed (Android 14).
 */
class AndroidEngine(private val context: Context, val options: TranscriberOptions) {
  val locale: String = options.localeTag

  /** Must run on the main thread, like every call into `SpeechRecognizer`. */
  private fun createRecognizer(): SpeechRecognizer {
    options.android.recognitionService?.let { name ->
      val component = ComponentName.unflattenFromString(name)
        ?: throw SpeechFailure(SpeechFailure.UNSUPPORTED, "$name is not a component name (package/class)")
      return SpeechRecognizer.createSpeechRecognizer(context, component)
    }
    if (options.onDevice) {
      if (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
        return SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
      }
      throw SpeechFailure(
        SpeechFailure.UNSUPPORTED,
        "This device has no on-device speech recognizer; `onDevice: false` uses the default one, which may send the audio to its service"
      )
    }
    if (!SpeechRecognizer.isRecognitionAvailable(context)) {
      throw SpeechFailure(SpeechFailure.UNSUPPORTED, "This device has no speech recognition service")
    }
    return SpeechRecognizer.createSpeechRecognizer(context)
  }

  /** Creates a recognizer and lets it go: fails the way a transcription would, on the main thread. */
  fun check() {
    createRecognizer().destroy()
  }

  private val formattingEnabled: Boolean
    get() = Build.VERSION.SDK_INT >= 33 && options.punctuation

  fun intent(audio: ParcelFileDescriptor?, microphone: Boolean): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
      putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, options.volatileResults)
      putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, options.android.maxResults ?: if (options.alternatives) 5 else 1)
      (options.android.preferOffline ?: options.onDevice.takeIf { it })?.let {
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, it)
      }

      if (Build.VERSION.SDK_INT >= 33) {
        if (options.punctuation) {
          val formatting = options.android.formatting
            ?: if (options.mode == "dictation" || microphone) "latency" else "quality"
          putExtra(
            RecognizerIntent.EXTRA_ENABLE_FORMATTING,
            if (formatting == "latency") RecognizerIntent.FORMATTING_OPTIMIZE_LATENCY else RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY
          )
        }
        options.android.hidePartialTrailingPunctuation?.let {
          putExtra(RecognizerIntent.EXTRA_HIDE_PARTIAL_TRAILING_PUNCTUATION, it)
        }
        options.maskOffensiveWords?.let { putExtra(RecognizerIntent.EXTRA_MASK_OFFENSIVE_WORDS, it) }
        options.android.biasingDeviceContext?.let { putExtra(RecognizerIntent.EXTRA_ENABLE_BIASING_DEVICE_CONTEXT, it) }
        if (options.contextualStrings.isNotEmpty()) {
          putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(options.contextualStrings))
        }
        if (audio != null) {
          putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, audio)
          putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
          putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
          putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RECOGNIZER_SAMPLE_RATE)
          // The session lasts as long as the audio does, and reports it segment by segment.
          putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
        }
      }

      if (Build.VERSION.SDK_INT >= 34) {
        putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_TIMING, true)
        putExtra(RecognizerIntent.EXTRA_REQUEST_WORD_CONFIDENCE, true)
        if (options.android.languageDetection) {
          putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
          if (options.android.languageDetectionAllowed.isNotEmpty()) {
            putStringArrayListExtra(
              RecognizerIntent.EXTRA_LANGUAGE_DETECTION_ALLOWED_LANGUAGES,
              ArrayList(options.android.languageDetectionAllowed)
            )
          }
        }
        options.android.languageSwitch?.let { mode ->
          putExtra(
            RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH,
            when (mode) {
              "highPrecision" -> RecognizerIntent.LANGUAGE_SWITCH_HIGH_PRECISION
              "quickResponse" -> RecognizerIntent.LANGUAGE_SWITCH_QUICK_RESPONSE
              else -> RecognizerIntent.LANGUAGE_SWITCH_BALANCED
            }
          )
          if (options.android.languageSwitchAllowed.isNotEmpty()) {
            putStringArrayListExtra(
              RecognizerIntent.EXTRA_LANGUAGE_SWITCH_ALLOWED_LANGUAGES,
              ArrayList(options.android.languageSwitchAllowed)
            )
          }
        }
      }
      if (Build.VERSION.SDK_INT >= 35) {
        // By name: the constants are flagged APIs.
        options.android.languageSwitchMaxSwitches?.let {
          putExtra("android.speech.extra.LANGUAGE_SWITCH_MAX_SWITCHES", it)
        }
        options.android.languageSwitchInitialActiveMillis?.let {
          putExtra("android.speech.extra.LANGUAGE_SWITCH_INITIAL_ACTIVE_DURATION_TIME_MILLIS", it)
        }
      }

      for ((key, value) in options.android.extras) {
        when (value) {
          is String -> putExtra(key, value)
          is Boolean -> putExtra(key, value)
          is Number -> if (value.toDouble() % 1 == 0.0) putExtra(key, value.toInt()) else putExtra(key, value.toDouble())
          is List<*> -> putStringArrayListExtra(key, ArrayList(value.filterIsInstance<String>()))
        }
      }
    }

  @Volatile private var modelReady = false
  private val modelLock = Mutex()

  /**
   * Installs the locale's on-device model when it is missing, once per engine, reporting the download as the
   * `installing` phase: the recognizer would fail with ERROR_LANGUAGE_UNAVAILABLE without it.
   */
  private suspend fun ensureModel(sink: EngineSink) {
    if (modelReady || !options.onDevice || options.android.recognitionService != null || Build.VERSION.SDK_INT < 33) {
      return
    }
    modelLock.withLock {
      if (modelReady) return
      val locales = SpeechLocales(context)
      val status = locales.status(locale, LocaleOptions(options.mode, onDevice = true))
      // The check's recognizer was just let go of; give the service a moment before the session binds to it.
      delay(300)
      when (status) {
        "installed" -> {}
        "unsupported" -> throw SpeechFailure(
          SpeechFailure.LOCALE_UNAVAILABLE, "The on-device recognizer has no model for $locale"
        )
        else -> {
          locales.install(locale) { fraction -> sink.progress(fraction, "installing") }
          sink.progress(1.0, "installing")
        }
      }
      modelReady = true
    }
  }

  /** Runs until the audio ends. One session at a time in the whole app: the recognition services take one. */
  suspend fun run(audio: EngineAudio, sink: EngineSink, silenceMillis: Long? = null) {
    ensureModel(sink)
    sessions.withLock {
      when (audio) {
        is EngineAudio.Stream -> runStream(audio, sink)
        is EngineAudio.RecognizerMicrophone -> runMicrophone(audio, sink, silenceMillis)
      }
    }
  }

  companion object {
    /** Google's on-device service runs one session at a time; a second fails with ERROR_RECOGNIZER_BUSY. */
    private val sessions = Mutex()

    /** How long the audio may take to start: a microphone that delivers nothing by then is a failure. */
    private const val FIRST_AUDIO_TIMEOUT_MILLIS = 8_000L
  }

  /**
   * A session over a stream, tried again (twice at most) when the service drops before it starts: a service that
   * another client just let go of can disconnect the next one. `feed` starts over each time.
   */
  private suspend fun runStream(audio: EngineAudio.Stream, sink: EngineSink) {
    if (Build.VERSION.SDK_INT < 33) {
      throw SpeechFailure(SpeechFailure.UNSUPPORTED, "Transcribing audio from a file needs Android 13")
    }
    var attempt = 0
    while (true) {
      try {
        return streamSession(audio, sink)
      } catch (failure: SpeechFailure) {
        if (!failure.retryable || attempt >= 2) throw failure
        attempt += 1
        delay(400L * attempt)
      }
    }
  }

  private suspend fun streamSession(audio: EngineAudio.Stream, sink: EngineSink) = coroutineScope {
    val (read, write) = ParcelFileDescriptor.createPipe()
    val output = ParcelFileDescriptor.AutoCloseOutputStream(write)
    val fed = AtomicLong(0)
    val clock = { audio.offset + fed.get().toDouble() / RECOGNIZER_SAMPLE_RATE }
    val done = CompletableDeferred<Unit>()
    val firstAudio = CompletableDeferred<Unit>()
    val listener = Listener(sink, done, clock, audio.offset)

    // A file is fed no faster than `feedSpeed` times real time: Google's on-device recognizer, fed at full speed,
    // finalizes segments late and drops some. The microphone comes in real time anyway.
    val speed = if (audio.duration != null) options.android.feedSpeed else Double.POSITIVE_INFINITY

    // The audio starts first, and the recognizer once it flows: an empty pipe at the start reads as the end of the
    // audio to Google's recognizer, and a microphone takes a moment to open. Until then the pipe holds the audio.
    val writer = launch(Dispatchers.IO) {
      val started = System.nanoTime()
      try {
        output.use { stream ->
          audio.feed { samples ->
            stream.write(samples.toLittleEndianBytes())
            val total = fed.addAndGet(samples.size.toLong())
            firstAudio.complete(Unit)
            if (speed.isFinite()) {
              val due = (total.toDouble() / RECOGNIZER_SAMPLE_RATE / speed * 1000).toLong()
              val elapsed = (System.nanoTime() - started) / 1_000_000
              if (due > elapsed) Thread.sleep(due - elapsed)
            }
            audio.duration?.takeIf { it > 0 }?.let { length ->
              sink.progress(minOf(1.0, (clock() - audio.offset) / length) * 0.99, "transcribing")
            }
          }
        }
        listener.audioEnded = true
        firstAudio.complete(Unit)
      } catch (_: IOException) {
        // The recognizer closed its end: it finished or failed, and says which through the listener.
      } catch (error: kotlinx.coroutines.CancellationException) {
        throw error
      } catch (error: Throwable) {
        // The audio failed (the microphone, a decoder): that is why the session ends, not the "no speech" the
        // recognizer reports for a closed pipe.
        val failure = SpeechFailure.from(error)
        firstAudio.completeExceptionally(failure)
        done.completeExceptionally(failure)
      }
    }

    var recognizer: SpeechRecognizer? = null
    try {
      withTimeoutOrNull(FIRST_AUDIO_TIMEOUT_MILLIS) { firstAudio.await() }
        ?: throw SpeechFailure(SpeechFailure.AUDIO, "No audio came from the microphone")

      recognizer = withContext(Dispatchers.Main) {
        createRecognizer().apply {
          setRecognitionListener(listener)
          startListening(intent(read, microphone = audio.duration == null))
        }
      }

      done.await()
      if (audio.duration != null) {
        sink.progress(1.0, "transcribing")
      }
    } finally {
      writer.cancel()
      recognizer?.let {
        withContext(NonCancellable + Dispatchers.Main) {
          it.cancel()
          it.destroy()
        }
      }
      runCatching { read.close() }
      runCatching { output.close() }
    }
  }

  private suspend fun runMicrophone(audio: EngineAudio.RecognizerMicrophone, sink: EngineSink, silenceMillis: Long?) {
    val started = System.nanoTime()
    val clock = { (System.nanoTime() - started) / 1e9 }

    while (!audio.stopped.isCompleted) {
      val done = CompletableDeferred<Unit>()
      val listener = Listener(sink, done, clock, 0.0)
      val recognizer = withContext(Dispatchers.Main) {
        createRecognizer().apply {
          setRecognitionListener(listener)
          startListening(
            intent(null, microphone = true).apply {
              silenceMillis?.let {
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, it)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, it)
              }
            }
          )
        }
      }
      val stopper = kotlinx.coroutines.CoroutineScope(Dispatchers.Main).launch {
        audio.stopped.await()
        recognizer.stopListening()
      }
      try {
        done.await()
      } finally {
        stopper.cancel()
        withContext(NonCancellable + Dispatchers.Main) { recognizer.destroy() }
      }
    }
  }

  /** Turns the recognizer's callbacks into results for the sink. */
  private inner class Listener(
    private val sink: EngineSink,
    private val done: CompletableDeferred<Unit>,
    private val clock: () -> Double,
    private val offset: Double
  ) : RecognitionListener {
    @Volatile var audioEnded = false
    private var ready = false
    private var lastEnd = offset
    private var language: String? = null
    private var gotResults = false

    override fun onReadyForSpeech(params: Bundle?) {
      ready = true
    }

    override fun onBeginningOfSpeech() {
      if (options.detectSpeech != null) sink.speech(true, clock())
    }

    override fun onRmsChanged(rmsdB: Float) {
      // About -2 for silence to 10 for loud speech, on Google's recognizer: stretched to the dBFS of the other path.
      sink.volume(((rmsdB - 10) * 5.0).coerceIn(-160.0, 0.0))
    }

    override fun onBufferReceived(buffer: ByteArray?) {}

    override fun onEndOfSpeech() {
      if (options.detectSpeech != null) sink.speech(false, clock())
    }

    override fun onError(error: Int) {
      when {
        SpeechFailure.isNoSpeech(error) -> done.complete(Unit)
        // A client error once all the audio went in (and results came) is the session ending, not a failure.
        error == SpeechRecognizer.ERROR_CLIENT && (audioEnded || gotResults) -> done.complete(Unit)
        error == SpeechRecognizer.ERROR_SERVER_DISCONNECTED && !ready && !gotResults -> done.completeExceptionally(
          SpeechFailure(SpeechFailure.SERVICE, "The recognition service disconnected before it started", retryable = true)
        )
        else -> done.completeExceptionally(SpeechFailure.fromRecognizer(error))
      }
    }

    override fun onResults(results: Bundle) {
      result(results, isFinal = true)?.let(::deliver)
      done.complete(Unit)
    }

    override fun onPartialResults(partialResults: Bundle) {
      result(partialResults, isFinal = false)?.let(sink::recognized)
    }

    override fun onSegmentResults(segmentResults: Bundle) {
      result(segmentResults, isFinal = true)?.let(::deliver)
    }

    override fun onEndOfSegmentedSession() {
      done.complete(Unit)
    }

    override fun onLanguageDetection(results: Bundle) {
      if (Build.VERSION.SDK_INT < 34) return
      val detected = results.getString(SpeechRecognizer.DETECTED_LANGUAGE) ?: return
      language = detected
      val confidence = when (results.getInt(SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL)) {
        SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_NOT_CONFIDENT -> "low"
        SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_CONFIDENT -> "medium"
        SpeechRecognizer.LANGUAGE_DETECTION_CONFIDENCE_LEVEL_HIGHLY_CONFIDENT -> "high"
        else -> "unknown"
      }
      val switchResult = if (results.containsKey(SpeechRecognizer.LANGUAGE_SWITCH_RESULT)) {
        when (results.getInt(SpeechRecognizer.LANGUAGE_SWITCH_RESULT)) {
          SpeechRecognizer.LANGUAGE_SWITCH_RESULT_SUCCEEDED -> "succeeded"
          SpeechRecognizer.LANGUAGE_SWITCH_RESULT_FAILED -> "failed"
          SpeechRecognizer.LANGUAGE_SWITCH_RESULT_SKIPPED_NO_MODEL -> "skippedNoModel"
          else -> "notAttempted"
        }
      } else {
        null
      }
      sink.language(detected, confidence, switchResult)
    }

    override fun onEvent(eventType: Int, params: Bundle?) {}

    private fun deliver(result: RecognizedResult) {
      gotResults = true
      lastEnd = maxOf(lastEnd, result.end)
      sink.recognized(result)
    }

    private fun result(bundle: Bundle, isFinal: Boolean): RecognizedResult? {
      val texts = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION) ?: return null
      val text = texts.firstOrNull()?.takeIf { it.isNotBlank() } ?: return null
      // 0 and -1 both mean the recognizer did not say: Google's on-device one reports 0 for everything.
      val score = bundle.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)?.firstOrNull()?.takeIf { it > 0 }?.toDouble()
      val parts = if (Build.VERSION.SDK_INT >= 34 && isFinal) parts(bundle) else emptyList()
      val runs = runs(text, parts).map { if (it.confidence == null && score != null) it.copy(confidence = score) else it }
      val timed = runs.filter { it.start != null }
      // Formatting puts the raw reading second; it is not an alternative.
      val alternatives = if (options.alternatives) {
        texts.drop(if (formattingEnabled) 2 else 1).filter { it != text }.distinct()
      } else {
        emptyList()
      }

      return RecognizedResult(
        runs = runs,
        start = timed.firstOrNull()?.start ?: lastEnd,
        end = timed.lastOrNull()?.end ?: maxOf(lastEnd, clock()),
        isFinal = isFinal,
        alternatives = alternatives,
        language = language
      )
    }

    @RequiresApi(34)
    private fun parts(bundle: Bundle): List<PartTiming> {
      val parts = bundle.getParcelableArrayList(SpeechRecognizer.RECOGNITION_PARTS, RecognitionPart::class.java)
        ?: return emptyList()
      // A recognizer that ignores the request for timing leaves every part at 0.
      if (parts.size > 1 && parts.all { it.timestampMillis == 0L }) {
        return parts.map { PartTiming(it.formattedText ?: it.rawText, null, confidence(it.confidenceLevel)) }
      }
      return parts.map {
        PartTiming(it.formattedText ?: it.rawText, it.timestampMillis / 1000.0 + offset, confidence(it.confidenceLevel))
      }
    }

    private fun confidence(level: Int): Double? = when (level) {
      1 -> 0.2
      2 -> 0.4
      3 -> 0.6
      4 -> 0.8
      5 -> 1.0
      else -> null
    }
  }
}

/** A recognized part: its text, when it starts (when timed) and how sure the recognizer is. */
data class PartTiming(val text: String, val start: Double?, val confidence: Double?)

/**
 * Lays the parts over the result's text: each part where its text is, the text between them untimed. A part ends
 * where the next begins, but no later than a generous time for its length: a pause after it is not part of it.
 */
fun runs(text: String, parts: List<PartTiming>): List<RecognizedRun> {
  val runs = mutableListOf<RecognizedRun>()
  var cursor = 0

  for ((index, part) in parts.withIndex()) {
    val at = text.indexOf(part.text, cursor)
    if (part.text.isEmpty() || at < 0) {
      continue
    }
    if (at > cursor) {
      runs.add(RecognizedRun(text.substring(cursor, at)))
    }
    val start = part.start
    val longest = 0.3 + part.text.length * 0.09
    val next = parts.drop(index + 1).firstOrNull { it.start != null }?.start
    val end = start?.let { if (next != null && next > it) minOf(next, it + longest) else it + longest }
    runs.add(RecognizedRun(part.text, start, end, part.confidence))
    cursor = at + part.text.length
  }
  if (cursor < text.length) {
    runs.add(RecognizedRun(text.substring(cursor)))
  }
  return runs
}
