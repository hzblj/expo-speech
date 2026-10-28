package com.hzblj.expospeech

import expo.modules.kotlin.AppContext
import expo.modules.kotlin.Promise
import expo.modules.kotlin.sharedobjects.SharedObject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

/** Where a finished transcript is kept, when the transcription has a `cacheKey`. */
data class CacheSlot(val key: String, val locale: String, val fingerprint: String)

/**
 * One transcription, shared with JavaScript as `Transcription`: a queued file or the microphone. Takes the engine's
 * results through `EngineSink`, keeps the transcript, and sends `update`, `stateChange`, `progress`, `speech`,
 * `volume` and `language` events.
 */
class TranscriptionObject(
  appContext: AppContext,
  val kind: String,
  locale: String,
  val cacheSlot: CacheSlot?,
  /** Higher first; equal priorities in order of arrival. */
  val priority: Int,
  val order: Long
) : SharedObject(appContext), EngineSink {
  val id: String = UUID.randomUUID().toString()

  private val lock = Any()
  private var assembler = TranscriptAssembler(locale)
  private var stateValue = "queued"
  private var fromCacheValue = false
  private var progressValue = 0.0
  private var failureValue: SpeechFailure? = null
  private val waiters = mutableListOf<Promise>()
  private var job: Job? = null
  private var capture: MicrophoneCapture? = null
  private var recognizerControl: MutableStateFlow<EngineAudio.RecognizerMicrophone.Control>? = null
  private var autoStop: AutoStop? = null
  private var paused = false
  private var cancelRequested = false
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

  /** Called once, when it settles: the transcriber takes it out of its queue. */
  var onSettled: ((TranscriptionObject) -> Unit)? = null

  val cacheKey: String? get() = cacheSlot?.key
  val state: String get() = synchronized(lock) { stateValue }
  val fromCache: Boolean get() = synchronized(lock) { fromCacheValue }
  val progress: Double get() = synchronized(lock) { progressValue }
  val failure: SpeechFailure? get() = synchronized(lock) { failureValue }
  val transcript: Transcript get() = synchronized(lock) { assembler.transcript }
  val isSettled: Boolean get() = state.let { it == "completed" || it == "cancelled" || it == "failed" }

  private fun send(event: String, payload: Map<String, Any?>) {
    appContext?.mainQueue?.launch { emit(event, payload) }
  }

  // Running

  fun complete(fromCache: Transcript) {
    synchronized(lock) {
      assembler = TranscriptAssembler(fromCache.locale, fromCache.segments).apply {
        duration = fromCache.duration
        audioUri = fromCache.audioUri
      }
      fromCacheValue = true
      progressValue = 1.0
    }
    settle("completed", null)
  }

  /** Transcribes a file: downloads it when remote, decodes it and streams it to the recognizer. */
  fun runFile(uri: String, options: TranscribeOptions, engine: AndroidEngine, downloads: AudioDownloads, cache: TranscriptCache) {
    run {
      if (!uri.startsWith("file:") && !uri.startsWith("/")) {
        setState("downloading")
      }
      val local = downloads.localFile(uri, options.headers) { fraction ->
        send("progress", mapOf("phase" to "downloading", "fraction" to fraction))
      }
      setState("preparing")
      // Opened once for the length and the range, then let go: each feed decodes with a decoder of its own.
      val decoder = AudioDecoder(local, options.rangeStart, options.rangeEnd).also { it.release() }
      synchronized(lock) {
        assembler.duration = decoder.duration
        assembler.audioUri = android.net.Uri.fromFile(local).toString()
      }
      val range = decoder.range
      setState("transcribing")
      engine.run(
        EngineAudio.Stream(
          // A new decoder per feed: a session the service dropped before it started is fed again from the start.
          feed = { from, write ->
            AudioDecoder(local, from, options.rangeEnd).decode { samples, _ ->
              write(samples)
              !cancelRequested
            }
          },
          isFile = true,
          offset = range.start,
          duration = if (decoder.duration > 0) minOf(range.endInclusive, decoder.duration) - range.start else null
        ),
        this
      )
      finish(cache)
    }
  }

  /** Transcribes the microphone until `stop`, or until `autoStop` says so. */
  fun runMicrophone(options: ListenOptions, engine: AndroidEngine, recordings: File) {
    val stopper = AutoStop.create(options.stopAfterSilenceMillis, options.stopWithoutSpeechMillis) { stop() }
    synchronized(lock) { autoStop = stopper }
    run {
      setState("transcribing")
      if (android.os.Build.VERSION.SDK_INT >= 33) {
        val recording = if (options.record) File(recordings, "${UUID.randomUUID()}.wav") else null
        val microphone = MicrophoneCapture(
          recording, options.volumeIntervalMillis, options.voiceProcessing, onStarted = { stopper?.start() }
        ) { level ->
          send("volume", mapOf("level" to level))
        }
        synchronized(lock) {
          microphone.muted = paused
          capture = microphone
          assembler.audioUri = recording?.let { android.net.Uri.fromFile(it).toString() }
        }
        engine.run(EngineAudio.Stream(feed = { _, write -> microphone.capture(write) }, isFile = false), this)
        synchronized(lock) { assembler.duration = microphone.duration }
      } else {
        val control = MutableStateFlow(
          if (synchronized(lock) { paused }) {
            EngineAudio.RecognizerMicrophone.Control.PAUSED
          } else {
            EngineAudio.RecognizerMicrophone.Control.LISTENING
          }
        )
        synchronized(lock) { recognizerControl = control }
        stopper?.start()
        engine.run(EngineAudio.RecognizerMicrophone(control), this, options.silenceMillis)
      }
      finish(null)
    }
  }

  private fun run(body: suspend () -> Unit) {
    val started = scope.launch {
      try {
        body()
      } catch (error: Throwable) {
        val failure = SpeechFailure.from(error)
        settle(if (failure.reason == SpeechFailure.CANCELLED || synchronized(lock) { cancelRequested }) "cancelled" else "failed", failure)
      }
    }
    synchronized(lock) { job = started }
  }

  private fun finish(cache: TranscriptCache?) {
    val transcript = synchronized(lock) {
      assembler.finalizeVolatile()
      progressValue = 1.0
      assembler.finalTranscript
    }
    if (synchronized(lock) { cancelRequested }) {
      settle("cancelled", SpeechFailure(SpeechFailure.CANCELLED, "The transcription was cancelled"))
      return
    }
    val slot = cacheSlot
    if (cache != null && slot != null) {
      cache.write(transcript, slot.key, slot.fingerprint)
    }
    settle("completed", null)
  }

  /** Stops listening and finalizes what was heard; for a file, cancels. */
  fun stop() {
    val (microphone, control) = synchronized(lock) { capture to recognizerControl }
    if (kind == "microphone" && !isSettled && (microphone != null || control != null)) {
      microphone?.stop()
      control?.value = EngineAudio.RecognizerMicrophone.Control.STOPPED
    } else {
      cancel()
    }
  }

  /** The microphone: silence until `resume`, in the state `paused`. Ignored for a file. */
  fun pause() = setPaused(true)

  fun resume() = setPaused(false)

  private fun setPaused(paused: Boolean) {
    if (kind != "microphone") return
    val running = synchronized(lock) {
      if (isSettledLocked() || this.paused == paused) return
      this.paused = paused
      capture?.muted = paused
      recognizerControl?.let { control ->
        if (control.value != EngineAudio.RecognizerMicrophone.Control.STOPPED) {
          control.value = if (paused) {
            EngineAudio.RecognizerMicrophone.Control.PAUSED
          } else {
            EngineAudio.RecognizerMicrophone.Control.LISTENING
          }
        }
      }
      stateValue == "transcribing" || stateValue == "paused"
    }
    synchronized(lock) { autoStop }?.setPaused(paused)
    if (running) {
      setState(if (paused) "paused" else "transcribing")
    }
  }

  fun cancel() {
    val (running, wasQueued) = synchronized(lock) {
      cancelRequested = true
      job to (stateValue == "queued" && job == null)
    }
    if (wasQueued) {
      settle("cancelled", SpeechFailure(SpeechFailure.CANCELLED, "The transcription was cancelled"))
      return
    }
    synchronized(lock) { capture }?.stop()
    running?.cancel()
  }

  // State

  /**
   * `transcribing` and `paused` follow `paused`, read here: a pause that crosses the start, or a late call, still ends
   * in the right one.
   */
  private fun setState(requested: String) {
    val changed = synchronized(lock) {
      val state = if (requested == "transcribing" || requested == "paused") {
        if (paused) "paused" else "transcribing"
      } else {
        requested
      }
      if (isSettledLocked() || stateValue == state) {
        null
      } else {
        stateValue = state
        state
      }
    } ?: return
    send("stateChange", mapOf("state" to changed, "error" to null))
  }

  private fun isSettledLocked() = stateValue == "completed" || stateValue == "cancelled" || stateValue == "failed"

  private fun settle(state: String, failure: SpeechFailure?) {
    val settled = synchronized(lock) {
      if (isSettledLocked()) {
        null
      } else {
        stateValue = state
        failureValue = failure
        autoStop?.cancel()
        val pending = waiters.toList()
        waiters.clear()
        pending to assembler.transcript
      }
    } ?: return

    send("stateChange", mapOf("state" to state, "error" to failure?.toMap()))
    for (promise in settled.first) {
      resolve(promise, state, failure, settled.second)
    }
    onSettled?.invoke(this)
    onSettled = null
    scope.cancel()
  }

  private fun resolve(promise: Promise, state: String, failure: SpeechFailure?, transcript: Transcript) {
    if (state == "completed") {
      promise.resolve(transcript.toMap())
    } else {
      val error = failure ?: SpeechFailure(SpeechFailure.CANCELLED, "The transcription was cancelled")
      promise.reject(error.reason, error.message, error)
    }
  }

  fun wait(promise: Promise) {
    val settled = synchronized(lock) {
      if (!isSettledLocked()) {
        waiters.add(promise)
        null
      } else {
        Triple(stateValue, failureValue, assembler.transcript)
      }
    } ?: return
    resolve(promise, settled.first, settled.second, settled.third)
  }

  // EngineSink

  override fun recognized(result: RecognizedResult) {
    val update = synchronized(lock) {
      if (isSettledLocked()) return
      val segments = if (result.isFinal) assembler.appendFinal(listOf(result)) else emptyList()
      if (!result.isFinal) {
        assembler.setVolatile(result)
      }
      mapOf("segments" to segments.map { it.toMap() }, "volatile" to assembler.currentVolatile?.toMap())
    }
    synchronized(lock) { autoStop }?.heard(result.text)
    send("update", update)
  }

  override fun speech(detected: Boolean, time: Double) {
    synchronized(lock) { autoStop }?.speech(detected)
    send("speech", mapOf("detected" to detected, "time" to time))
  }

  override fun progress(fraction: Double, phase: String) {
    if (phase == "transcribing") {
      synchronized(lock) { progressValue = fraction }
    }
    send("progress", mapOf("phase" to phase, "fraction" to fraction))
  }

  override fun volume(level: Double) {
    send("volume", mapOf("level" to level))
  }

  override fun language(locale: String, confidence: String, switchResult: String?) {
    send("language", mapOf("locale" to locale, "confidence" to confidence, "switchResult" to switchResult))
  }
}
