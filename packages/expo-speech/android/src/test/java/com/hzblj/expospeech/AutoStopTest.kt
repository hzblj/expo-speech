package com.hzblj.expospeech

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** `autoStop`'s timing, at a few tens of milliseconds. The same cases as `AutoStopTests.swift`. */
class AutoStopTest {
  private fun make(afterSilence: Long?, withoutSpeech: Long?): Pair<AutoStop, AtomicInteger> {
    val fired = AtomicInteger(0)
    return AutoStop.create(afterSilence, withoutSpeech) { fired.incrementAndGet() }!! to fired
  }

  @Test
  fun offWhenNeitherIsSet() {
    assertNull(AutoStop.create(null, null) {})
  }

  @Test
  fun stopsWhenNothingIsSaid() {
    val firedAt = AtomicLong(0)
    val autoStop = AutoStop.create(50, 100) { firedAt.set(System.nanoTime()) }!!
    val started = System.nanoTime()
    autoStop.start()
    Thread.sleep(250)
    assertTrue(firedAt.get() > 0)
    assertTrue((firedAt.get() - started) / 1_000_000 >= 100)
  }

  @Test
  fun waitsForTheMicrophoneToOpen() {
    val (_, fired) = make(50, 50)
    Thread.sleep(150)
    assertEquals(0, fired.get())
  }

  @Test
  fun eachNewTextRestartsTheSilence() {
    val (autoStop, fired) = make(100, null)
    autoStop.start()
    autoStop.heard("box")
    Thread.sleep(60)
    autoStop.heard("box box")
    Thread.sleep(60)
    assertEquals(0, fired.get())
    Thread.sleep(100)
    assertEquals(1, fired.get())
  }

  @Test
  fun punctuationAddedAsAResultSettlesIsNotSpeech() {
    val (autoStop, fired) = make(100, null)
    autoStop.start()
    autoStop.heard("box this lap")
    Thread.sleep(60)
    autoStop.heard("Box this lap.")
    Thread.sleep(70)
    assertEquals(1, fired.get())
  }

  @Test
  fun withoutAfterSilenceItRunsOnOnceSomethingIsHeard() {
    val (autoStop, fired) = make(null, 50)
    autoStop.start()
    autoStop.heard("push now")
    Thread.sleep(150)
    assertEquals(0, fired.get())
  }

  @Test
  fun nothingFiresWhileSpeechIsDetected() {
    val (autoStop, fired) = make(50, 50)
    autoStop.start()
    autoStop.speech(true)
    Thread.sleep(150)
    assertEquals(0, fired.get())
    autoStop.speech(false)
    Thread.sleep(150)
    assertEquals(1, fired.get())
  }

  @Test
  fun pausingHoldsTheWaitAndResumingStartsItAgain() {
    val (autoStop, fired) = make(100, null)
    autoStop.start()
    autoStop.heard("box")
    autoStop.setPaused(true)
    Thread.sleep(200)
    assertEquals(0, fired.get())
    autoStop.setPaused(false)
    Thread.sleep(50)
    assertEquals(0, fired.get())
    Thread.sleep(150)
    assertEquals(1, fired.get())
  }

  @Test
  fun firesOnceAndNeverAfterCancel() {
    val (autoStop, fired) = make(30, 30)
    autoStop.start()
    Thread.sleep(100)
    autoStop.heard("again")
    Thread.sleep(100)
    assertEquals(1, fired.get())

    val (cancelled, none) = make(30, 30)
    cancelled.start()
    cancelled.cancel()
    Thread.sleep(100)
    assertEquals(0, none.get())
  }
}
