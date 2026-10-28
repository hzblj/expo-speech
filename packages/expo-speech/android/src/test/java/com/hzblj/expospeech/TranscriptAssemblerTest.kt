package com.hzblj.expospeech

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.PI
import kotlin.math.sin

class TranscriptAssemblerTest {
  private fun Transcript.slice(word: TranscriptWord) = text.substring(word.range.first, word.range.last + 1)

  @Test
  fun androidSegmentsAreJoinedWithASpace() {
    val assembler = TranscriptAssembler("en-GB")
    assembler.appendFinal(listOf(RecognizedResult(listOf(RecognizedRun("Box box")), 0.0, 1.0, true)))
    val second = assembler.appendFinal(listOf(RecognizedResult(listOf(RecognizedRun("push now")), 1.0, 2.0, true)))[0]

    assertEquals("Box box push now", assembler.transcript.text)
    assertEquals(7..15, second.range)
    assertEquals("push", assembler.transcript.slice(second.words[0]))
  }

  @Test
  fun timedPartsKeepTheirTimes() {
    val runs = runs(
      "Box this lap.",
      listOf(PartTiming("Box", 0.5, 0.8), PartTiming("this", 0.9, 1.0), PartTiming("lap.", 1.2, 0.6))
    )
    val segment = TranscriptAssembler("en-GB").appendFinal(listOf(RecognizedResult(runs, 0.5, 1.6, true)))[0]

    assertEquals(listOf("Box", "this", "lap."), segment.words.map { it.text })
    assertEquals(listOf("measured", "measured", "measured"), segment.words.map { it.timing })
    assertEquals(0.9, segment.words[0].end, 1e-9)
    assertEquals(1.2, segment.words[2].start, 1e-9)
    assertEquals(0.8, segment.words.map { it.confidence!! }.average(), 1e-9)
  }

  @Test
  fun aPartBeforeAPauseEndsWithinItsLength() {
    val runs = runs("Copy. Box now.", listOf(PartTiming("Copy.", 1.0, null), PartTiming("Box", 9.0, null), PartTiming("now.", 9.3, null)))

    assertTrue(runs[0].end!! < 2.0)
    assertEquals(9.3, runs[2].end!!, 1e-9)
  }

  @Test
  fun untimedTextIsSpreadOverTheResult() {
    val segment = TranscriptAssembler("en-GB").appendFinal(
      listOf(RecognizedResult(listOf(RecognizedRun("Verstappen is two")), 2.0, 4.0, true))
    )[0]

    assertEquals(listOf("estimated", "estimated", "estimated"), segment.words.map { it.timing })
    assertEquals(2.0, segment.words[0].start, 1e-9)
    assertEquals(4.0, segment.words[2].end, 1e-9)
  }

  @Test
  fun punctuationInAPartOfItsOwnStaysWithItsWord() {
    val runs = listOf(RecognizedRun("heating", 4.68, 5.2), RecognizedRun(".", 6.72, 6.72), RecognizedRun(" I", 6.72, 6.75))
    val words = TranscriptAssembler("en-GB").appendFinal(listOf(RecognizedResult(runs, 4.68, 6.75, true)))[0].words

    assertEquals(listOf("heating.", "I"), words.map { it.text })
    assertEquals(6.72, words[0].end, 1e-9)
  }

  @Test
  fun theVolatileSegmentIsReplacedAndSettledByAFinalOne() {
    val assembler = TranscriptAssembler("en-GB")
    assembler.setVolatile(RecognizedResult(listOf(RecognizedRun("Box bo")), 0.0, 1.0, false))
    assertEquals("Box bo", assembler.transcript.text)

    assembler.appendFinal(listOf(RecognizedResult(listOf(RecognizedRun("Box box")), 0.0, 1.0, true)))
    assertNull(assembler.currentVolatile)

    assembler.setVolatile(RecognizedResult(listOf(RecognizedRun("push")), 1.0, 2.0, false))
    assertEquals("Box box push", assembler.transcript.text)
    assertEquals("Box box", assembler.finalTranscript.text)
  }

  @Test
  fun offsetsCountUtf16LikeJavaScript() {
    val assembler = TranscriptAssembler("cs-CZ")
    assembler.appendFinal(listOf(RecognizedResult(listOf(RecognizedRun("Boxuj 🏁 teď")), 0.0, 1.0, true)))
    val transcript = assembler.transcript

    assertEquals(listOf("Boxuj", "🏁", "teď"), transcript.words.map { transcript.slice(it) })
    assertEquals(listOf(6, 8), transcript.words[1].toMap()["range"])
  }

  @Test
  fun aTranscriptSurvivesTheCache() {
    val assembler = TranscriptAssembler("en-GB")
    assembler.appendFinal(listOf(RecognizedResult(listOf(RecognizedRun("Box", 0.0, 0.4, 0.9)), 0.0, 0.4, true)))
    assembler.duration = 3.5
    val transcript = assembler.finalTranscript

    assertEquals(transcript, Transcript.fromJson(transcript.toJson()))
  }

  @Test
  fun theResamplerKeepsTheLengthAndTheTone() {
    val source = 44_100
    // One second of a 440 Hz tone, the same in both channels.
    val input = ShortArray(source * 2) { (sin(2 * PI * 440 * (it / 2) / source) * 12_000).toInt().toShort() }
    val resampler = Resampler(source, 2)
    val output = mutableListOf<Short>()
    // Stereo, in uneven chunks, as a decoder hands them out.
    var index = 0
    while (index < input.size) {
      val end = minOf(input.size, index + 3_302)
      output.addAll(resampler.process(input.copyOfRange(index, end)).toList())
      index = end
    }

    assertEquals(16_000.0, output.size.toDouble(), 20.0)
    val crossings = output.zipWithNext().count { (a, b) -> a < 0 && b >= 0 }
    assertEquals(440.0, crossings.toDouble(), 3.0)
  }

  @Test
  fun aWavFileHasItsHeaderAndLength() {
    val file = File.createTempFile("expo-speech", ".wav")
    val writer = WavWriter(file)
    writer.write(ShortArray(16_000) { 1000 }.toLittleEndianBytes())
    writer.close()

    val bytes = file.readBytes()
    assertEquals("RIFF", String(bytes, 0, 4))
    assertEquals("WAVE", String(bytes, 8, 4))
    assertEquals(44 + 32_000, bytes.size)
    assertEquals(1.0, writer.durationSeconds, 1e-9)
  }

  @Test
  fun optionsTakeTheirDefaults() {
    val options = TranscriberOptions.from(
      mapOf("locale" to "en-GB", "detectSpeech" to true, "android" to mapOf("languageDetection" to mapOf("allowedLanguages" to listOf("en-GB"))))
    )

    assertEquals("transcription", options.mode)
    assertEquals("required", options.onDevice)
    assertEquals("medium", options.detectSpeech)
    assertTrue(options.android.languageDetection)
    assertEquals(listOf("en-GB"), options.android.languageDetectionAllowed)
    assertEquals(1, options.maxConcurrent)
    assertEquals("preferred", TranscriberOptions.from(mapOf("onDevice" to "preferred")).onDevice)
    assertEquals("required", TranscriberOptions.from(mapOf("onDevice" to "anywhere")).onDevice)
  }

  @Test
  fun listenOptions() {
    val options = ListenOptions.from(
      mapOf(
        "autoStop" to mapOf("afterSilence" to 1500.0, "withoutSpeech" to 5000.0),
        "voiceProcessing" to true,
        "android" to mapOf("silenceMillis" to 900.0)
      )
    )

    assertEquals(1500L, options.stopAfterSilenceMillis)
    assertEquals(5000L, options.stopWithoutSpeechMillis)
    assertTrue(options.voiceProcessing)
    assertEquals(900L, options.silenceMillis)
    assertEquals(null, ListenOptions.from(null).stopAfterSilenceMillis)
  }
}
