package com.hzblj.expospeech

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt

/** What the recognizer takes through `EXTRA_AUDIO_SOURCE`, and what recordings are written in. */
const val RECOGNIZER_SAMPLE_RATE = 16_000

/**
 * Mixes interleaved 16-bit PCM down to mono and resamples it to `target`, chunk by chunk, keeping its state across
 * chunks so the joins are seamless. Downsampling goes through a windowed-sinc low-pass first: without it the
 * sibilants of 44.1 kHz audio fold back into the speech band as noise.
 */
class Resampler(private val source: Int, private val channels: Int, private val target: Int = RECOGNIZER_SAMPLE_RATE) {
  private val ratio = source.toDouble() / target
  private val taps: FloatArray
  private val history: FloatArray
  private var position = 0.0
  private var buffered = FloatArray(0)

  init {
    // Cut at 90 % of the target's Nyquist frequency, 31 taps, Hann window.
    val cutoff = 0.45 * minOf(1.0, target.toDouble() / source)
    val count = if (source > target) 31 else 1
    taps = FloatArray(count) { index ->
      if (count == 1) {
        1f
      } else {
        val centre = index - (count - 1) / 2.0
        val sinc = if (centre == 0.0) 2 * cutoff else sin(2 * PI * cutoff * centre) / (PI * centre)
        val window = 0.5 - 0.5 * kotlin.math.cos(2 * PI * index / (count - 1))
        (sinc * window).toFloat()
      }
    }
    val sum = taps.sum()
    for (index in taps.indices) {
      taps[index] /= sum
    }
    history = FloatArray(count - 1)
  }

  /** Resamples a chunk of interleaved little-endian 16-bit samples into mono 16-bit samples. */
  fun process(input: ShortArray, length: Int = input.size): ShortArray {
    val frames = length / channels
    val mono = FloatArray(history.size + frames)

    history.copyInto(mono)
    for (frame in 0 until frames) {
      var sum = 0f
      for (channel in 0 until channels) {
        sum += input[frame * channels + channel]
      }
      mono[history.size + frame] = sum / channels
    }

    // Filtered samples, aligned with the input frames of this chunk.
    val filtered = FloatArray(frames)
    for (frame in 0 until frames) {
      var sum = 0f
      for (tap in taps.indices) {
        sum += mono[frame + tap] * taps[tap]
      }
      filtered[frame] = sum
    }
    if (history.isNotEmpty()) {
      mono.copyInto(history, 0, mono.size - history.size, mono.size)
    }

    // Linear interpolation over what is buffered from the last chunk and this one.
    val samples = FloatArray(buffered.size + filtered.size)
    buffered.copyInto(samples)
    filtered.copyInto(samples, buffered.size)

    val output = ArrayList<Short>((frames / ratio).toInt() + 2)
    while (position + 1 < samples.size) {
      val index = position.toInt()
      val fraction = (position - index).toFloat()
      val value = samples[index] * (1 - fraction) + samples[index + 1] * fraction
      output.add(value.coerceIn(Short.MIN_VALUE.toFloat(), Short.MAX_VALUE.toFloat()).toInt().toShort())
      position += ratio
    }

    val consumed = position.toInt()
    buffered = samples.copyOfRange(minOf(consumed, samples.size), samples.size)
    position -= consumed
    return output.toShortArray()
  }
}

fun ShortArray.toLittleEndianBytes(length: Int = size): ByteArray {
  val buffer = ByteBuffer.allocate(length * 2).order(ByteOrder.LITTLE_ENDIAN)
  for (index in 0 until length) {
    buffer.putShort(this[index])
  }
  return buffer.array()
}

/** The level of 16-bit samples in dBFS, from -160 (silence) to 0. */
fun levelOf(samples: ShortArray, length: Int = samples.size): Double {
  if (length == 0) {
    return -160.0
  }
  var sum = 0.0
  for (index in 0 until length) {
    val value = samples[index] / 32768.0
    sum += value * value
  }
  val rms = sqrt(sum / length)
  return if (rms > 0) maxOf(-160.0, 20 * log10(rms)) else -160.0
}

/** A mono 16-bit WAV file written as samples come; the header is completed on `close`. */
class WavWriter(file: File, private val sampleRate: Int = RECOGNIZER_SAMPLE_RATE) {
  private val output: RandomAccessFile
  private var bytes = 0L

  init {
    // The folder first: opening a file in a folder that isn't there throws.
    file.parentFile?.mkdirs()
    output = RandomAccessFile(file, "rw")
    output.setLength(0)
    output.write(header(0))
  }

  fun write(data: ByteArray, length: Int = data.size) {
    output.write(data, 0, length)
    bytes += length
  }

  fun close() {
    output.seek(0)
    output.write(header(bytes))
    output.close()
  }

  val durationSeconds: Double get() = bytes / 2.0 / sampleRate

  private fun header(dataBytes: Long): ByteArray =
    ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
      put("RIFF".toByteArray())
      putInt((36 + dataBytes).toInt())
      put("WAVE".toByteArray())
      put("fmt ".toByteArray())
      putInt(16)
      putShort(1)
      putShort(1)
      putInt(sampleRate)
      putInt(sampleRate * 2)
      putShort(2)
      putShort(16)
      put("data".toByteArray())
      putInt(dataBytes.toInt())
    }.array()
}
