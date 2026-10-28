package com.hzblj.expospeech

import org.junit.Assert.assertEquals
import org.junit.Test

/** A live meter's levels. The same cases as `LevelMeterTests.swift`. */
class LevelMeterTest {
  private fun shorts(vararg values: Double) = ShortArray(values.size) { (values[it] * 32768).toInt().coerceIn(-32768, 32767).toShort() }

  @Test
  fun oneLevelPerStretchAcrossChunks() {
    val meter = LevelMeter(4)
    assertEquals(emptyList<Double>(), meter.add(shorts(0.5, -0.5, 0.5)))
    val next = meter.add(shorts(-0.5, 0.0, 0.0, 0.0, 0.0, 1.0))
    assertEquals(2, next.size)
    assertEquals(0.5, next[0], 1e-3)
    assertEquals(0.0, next[1], 1e-3)
    assertEquals(1.0, meter.add(shorts(1.0, 1.0, 1.0)).single(), 1e-3)
  }

  @Test
  fun atLeastOneFrame() {
    val levels = LevelMeter(0).add(shorts(0.25, -0.25))
    assertEquals(2, levels.size)
    assertEquals(0.25, levels[0], 1e-3)
  }
}
