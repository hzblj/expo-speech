package com.hzblj.expospeech

import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * `autoStop` for the microphone: fires once, `afterSilence` milliseconds after the last thing heard, or `withoutSpeech`
 * milliseconds after the microphone opened while nothing has been. Heard is text that changed (letters and digits only,
 * so a result that only gains punctuation or capitals as it settles is not new speech) or speech detected. Nothing
 * fires while speech is detected or while paused; either restarts the wait when it ends. The same rules as
 * `ios/Core/AutoStop.swift`.
 */
class AutoStop private constructor(
  private val afterSilenceMillis: Long?,
  private val withoutSpeechMillis: Long?,
  private val onFire: () -> Unit
) {
  private val lock = Any()
  private var generation = 0
  private var pending: ScheduledFuture<*>? = null
  private var started = false
  private var heardAnything = false
  private var speaking = false
  private var paused = false
  private var finished = false
  private var lastText = ""

  companion object {
    private val timer = Executors.newSingleThreadScheduledExecutor { task ->
      Thread(task, "expo-speech-auto-stop").apply { isDaemon = true }
    }

    /** `null` when both are off. */
    fun create(afterSilenceMillis: Long?, withoutSpeechMillis: Long?, onFire: () -> Unit): AutoStop? =
      if (afterSilenceMillis == null && withoutSpeechMillis == null) {
        null
      } else {
        AutoStop(afterSilenceMillis, withoutSpeechMillis, onFire)
      }
  }

  /** The microphone opened: the wait for speech starts. */
  fun start() = update { started = true }

  /** A result's text; only a change counts. */
  fun heard(text: String) {
    val words = text.lowercase().filter { it.isLetterOrDigit() }
    reschedule {
      if (words.isEmpty() || words == lastText) {
        false
      } else {
        lastText = words
        heardAnything = true
        true
      }
    }
  }

  fun speech(detected: Boolean) = update {
    speaking = detected
    heardAnything = heardAnything || detected
  }

  fun setPaused(paused: Boolean) = update { this.paused = paused }

  /** Never fires after this. */
  fun cancel() = update { finished = true }

  private fun update(change: () -> Unit) = reschedule {
    change()
    true
  }

  /** Applies the change and, when it changed anything, replaces the pending wait with the one the state calls for. */
  private fun reschedule(change: () -> Boolean) {
    synchronized(lock) {
      if (!change()) return
      generation += 1
      pending?.cancel(false)
      pending = null
      if (!started || finished || speaking || paused) return
      val delay = (if (heardAnything) afterSilenceMillis else withoutSpeechMillis) ?: return
      val scheduled = generation
      pending = timer.schedule({ fire(scheduled) }, delay, TimeUnit.MILLISECONDS)
    }
  }

  private fun fire(scheduled: Int) {
    val due = synchronized(lock) {
      if (scheduled != generation || finished) {
        false
      } else {
        finished = true
        true
      }
    }
    if (due) onFire()
  }
}
