package com.hzblj.expospeech

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.coroutineContext

/**
 * The microphone through `AudioRecord`, at the recognizer's 16 kHz mono 16-bit: fed to the recognizer, optionally
 * written to a WAV file and metered. Runs until `stop`. `muted` sends silence in place of what the microphone hears,
 * so the recognizer, the recording and the times go on without a gap. `voiceProcessing` records from the voice
 * communication source with the platform's echo canceler and noise suppressor, where the device has them.
 */
class MicrophoneCapture(
  private val recording: File?,
  private val volumeIntervalMillis: Long,
  private val voiceProcessing: Boolean = false,
  private val onStarted: () -> Unit = {},
  /** The root mean square of every `LEVEL_INTERVAL_SECONDS` of audio, from 0 to 1 (0 while muted), for a live meter. */
  private val onLevel: ((Double) -> Unit)? = null,
  private val onVolume: (Double) -> Unit
) {
  companion object {
    const val LEVEL_INTERVAL_SECONDS = 0.08
  }

  @Volatile private var stopped = false
  @Volatile var muted = false
  private var writer: WavWriter? = null

  /** Seconds captured. */
  @Volatile var duration = 0.0
    private set

  fun stop() {
    stopped = true
  }

  /** Reads until `stop`, handing every chunk to `write`. The caller holds the RECORD_AUDIO permission. */
  @SuppressLint("MissingPermission")
  suspend fun capture(write: (ShortArray) -> Unit) = withContext(Dispatchers.IO) {
    val minimum = AudioRecord.getMinBufferSize(
      RECOGNIZER_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
    )
    if (minimum <= 0) {
      throw SpeechFailure(SpeechFailure.AUDIO, "The microphone cannot record at 16 kHz")
    }
    val record = try {
      AudioRecord(
        if (voiceProcessing) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.VOICE_RECOGNITION,
        RECOGNIZER_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, RECOGNIZER_SAMPLE_RATE / 5 * 2)
      )
    } catch (error: SecurityException) {
      throw SpeechFailure(SpeechFailure.PERMISSION_DENIED, "The microphone is not allowed", error)
    }
    if (record.state != AudioRecord.STATE_INITIALIZED) {
      record.release()
      throw SpeechFailure(SpeechFailure.AUDIO, "The microphone could not be opened")
    }

    val buffer = ShortArray(RECOGNIZER_SAMPLE_RATE / 10)
    var samples = 0L
    var lastVolume = 0L
    val levels = LevelMeter((RECOGNIZER_SAMPLE_RATE * LEVEL_INTERVAL_SECONDS).toInt())
    val effects = if (voiceProcessing) voiceEffects(record.audioSessionId) else emptyList()
    try {
      writer = recording?.let { WavWriter(it) }
      record.startRecording()
      onStarted()
      while (!stopped && coroutineContext.isActive) {
        val read = record.read(buffer, 0, buffer.size)
        if (read < 0) {
          throw SpeechFailure(SpeechFailure.AUDIO, "The microphone stopped (error $read)")
        }
        if (read == 0) continue

        val chunk = if (muted) ShortArray(read) else buffer.copyOf(read)
        onLevel?.let { report -> levels.add(chunk).forEach(report) }
        write(chunk)
        writer?.write(chunk.toLittleEndianBytes())
        samples += read
        duration = samples.toDouble() / RECOGNIZER_SAMPLE_RATE

        val now = System.currentTimeMillis()
        if (volumeIntervalMillis > 0 && now - lastVolume >= volumeIntervalMillis) {
          lastVolume = now
          onVolume(levelOf(chunk))
        }
      }
    } finally {
      runCatching { record.stop() }
      record.release()
      effects.forEach { runCatching { it.release() } }
      writer?.close()
      writer = null
    }
  }

  /** The echo canceler and noise suppressor on the recording's session, those the device has. */
  private fun voiceEffects(session: Int): List<AudioEffect> =
    listOfNotNull(
      if (AcousticEchoCanceler.isAvailable()) runCatching { AcousticEchoCanceler.create(session) }.getOrNull() else null,
      if (NoiseSuppressor.isAvailable()) runCatching { NoiseSuppressor.create(session) }.getOrNull() else null
    ).onEach { effect -> runCatching { effect.enabled = true } }
}
