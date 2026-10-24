package com.hzblj.expospeech

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteOrder

/**
 * Decodes the audio track of any file the platform reads (mp3, m4a, aac, wav, ogg, flac, the audio of mp4) into
 * 16 kHz mono 16-bit PCM, what `EXTRA_AUDIO_SOURCE` takes. Chunks are handed out as they are decoded, so a long file
 * never sits in memory and a full pipe to the recognizer slows the decoding down.
 */
class AudioDecoder(private val file: File, private val start: Double? = null, private val end: Double? = null) {
  /** The file's length in seconds, or 0 when the container does not say. */
  val duration: Double

  private val extractor = MediaExtractor()
  private val track: Int
  private val format: MediaFormat

  init {
    if (!file.exists()) {
      throw SpeechFailure(SpeechFailure.AUDIO, "There is no file at ${file.path}")
    }
    try {
      extractor.setDataSource(file.path)
    } catch (error: Exception) {
      throw SpeechFailure(SpeechFailure.AUDIO, "The file could not be read: ${error.message}", error)
    }
    track = (0 until extractor.trackCount).firstOrNull {
      extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
    } ?: throw SpeechFailure(SpeechFailure.AUDIO, "The file has no audio track")
    format = extractor.getTrackFormat(track)
    duration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0 else 0.0
  }

  /** Lets go of the file without decoding it. */
  fun release() {
    extractor.release()
  }

  /** The seconds of the file that are read. */
  val range: ClosedFloatingPointRange<Double>
    get() = (start ?: 0.0)..(end ?: if (duration > 0) duration else Double.MAX_VALUE)

  /**
   * Decodes on the calling thread, handing each chunk of 16 kHz mono samples to `onChunk` with its start in the file's
   * seconds. Returns early when `onChunk` returns false.
   */
  fun decode(onChunk: (samples: ShortArray, start: Double) -> Boolean) {
    val mime = format.getString(MediaFormat.KEY_MIME)!!
    val codec = try {
      MediaCodec.createDecoderByType(mime).apply {
        configure(format, null, null, 0)
        start()
      }
    } catch (error: Exception) {
      throw SpeechFailure(SpeechFailure.AUDIO, "The audio ($mime) cannot be decoded on this device: ${error.message}", error)
    }

    extractor.selectTrack(track)
    val startUs = ((start ?: 0.0) * 1_000_000).toLong()
    val endUs = end?.let { (it * 1_000_000).toLong() }
    if (startUs > 0) {
      extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
    }

    var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    var floats = false
    var resampler = Resampler(sampleRate, channels)
    var produced = 0L
    val info = MediaCodec.BufferInfo()
    var inputDone = false

    try {
      while (true) {
        if (!inputDone) {
          val index = codec.dequeueInputBuffer(10_000)
          if (index >= 0) {
            val buffer = codec.getInputBuffer(index)!!
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0 || (endUs != null && extractor.sampleTime > endUs)) {
              codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              codec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
              extractor.advance()
            }
          }
        }

        val index = codec.dequeueOutputBuffer(info, 10_000)
        when {
          index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            val output = codec.outputFormat
            sampleRate = output.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            floats = output.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
              output.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
            resampler = Resampler(sampleRate, channels)
          }
          index >= 0 -> {
            val buffer = codec.getOutputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
            buffer.position(info.offset)
            buffer.limit(info.offset + info.size)

            var samples = if (floats) {
              val values = buffer.asFloatBuffer()
              ShortArray(values.remaining()) { (values.get(it).coerceIn(-1f, 1f) * Short.MAX_VALUE).toInt().toShort() }
            } else {
              val values = buffer.asShortBuffer()
              ShortArray(values.remaining()).also { values.get(it) }
            }
            codec.releaseOutputBuffer(index, false)

            // Frames before the range start, after a seek to the sync sample before it.
            if (info.presentationTimeUs < startUs) {
              val skip = ((startUs - info.presentationTimeUs) * sampleRate / 1_000_000).toInt() * channels
              samples = if (skip >= samples.size) ShortArray(0) else samples.copyOfRange(skip, samples.size)
            }
            if (endUs != null && info.presentationTimeUs > endUs) {
              samples = ShortArray(0)
            }

            if (samples.isNotEmpty()) {
              val mono = resampler.process(samples)
              val chunkStart = (start ?: 0.0) + produced.toDouble() / RECOGNIZER_SAMPLE_RATE
              produced += mono.size
              if (mono.isNotEmpty() && !onChunk(mono, chunkStart)) {
                return
              }
            }
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
              return
            }
          }
        }
      }
    } finally {
      codec.stop()
      codec.release()
      extractor.release()
    }
  }
}
