package com.hzblj.expospeech

import kotlin.math.sqrt

/**
 * The root mean square of each stretch of `frames` samples, as the samples come in chunks of any size: a live meter's
 * levels, from 0 to 1. The same rules as `ios/Core/LevelMeter.swift`.
 */
class LevelMeter(frames: Int) {
  private val frames = maxOf(1, frames)
  private var sum = 0.0
  private var count = 0

  /** The levels of the stretches these samples complete; a stretch they leave open goes on with the next ones. */
  fun add(samples: ShortArray): List<Double> {
    val levels = mutableListOf<Double>()
    for (sample in samples) {
      val value = sample / 32768.0
      sum += value * value
      count += 1
      if (count >= frames) {
        levels.add(minOf(1.0, sqrt(sum / count)))
        sum = 0.0
        count = 0
      }
    }
    return levels
  }
}
