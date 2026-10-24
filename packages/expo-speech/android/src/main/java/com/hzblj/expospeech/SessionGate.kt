package com.hzblj.expospeech

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred

/**
 * One recognizer session at a time in the whole app, the microphone first. Google's on-device service takes one
 * session (a second gets ERROR_RECOGNIZER_BUSY), and someone holding the talk button should not wait for a queue of
 * files: the microphone goes before every file waiting, and a file session that is running is asked to make way.
 * It stops, and continues from where its final text ends once the microphone is done.
 */
internal object SessionGate {
  class Turn internal constructor(val microphone: Boolean) {
    internal val granted = CompletableDeferred<Unit>()
    @Volatile internal var preempt: (() -> Unit)? = null
  }

  private val lock = Any()
  private var holder: Turn? = null
  private val waiting = mutableListOf<Turn>()

  suspend fun <T> use(microphone: Boolean, body: suspend (Turn) -> T): T {
    val turn = acquire(microphone)
    try {
      return body(turn)
    } finally {
      release(turn)
    }
  }

  private suspend fun acquire(microphone: Boolean): Turn {
    val turn = Turn(microphone)
    var preempt: (() -> Unit)? = null

    synchronized(lock) {
      if (holder == null) {
        holder = turn
        turn.granted.complete(Unit)
      } else {
        val firstFile = waiting.indexOfFirst { !it.microphone }
        waiting.add(if (microphone && firstFile >= 0) firstFile else waiting.size, turn)
        if (microphone && holder?.microphone == false) {
          preempt = holder?.preempt
        }
      }
    }
    preempt?.invoke()

    try {
      turn.granted.await()
    } catch (error: CancellationException) {
      // Cancelled while waiting, or just as the turn came: it passes on either way.
      val granted = synchronized(lock) {
        waiting.remove(turn)
        holder === turn
      }
      if (granted) {
        release(turn)
      }
      throw error
    }
    return turn
  }

  /** How a file session makes way. Called at once when the microphone is already waiting. */
  fun onPreempt(turn: Turn, preempt: () -> Unit) {
    val now = synchronized(lock) {
      turn.preempt = preempt
      !turn.microphone && waiting.any { it.microphone }
    }
    if (now) {
      preempt()
    }
  }

  private fun release(turn: Turn) {
    val next = synchronized(lock) {
      if (holder !== turn) {
        return
      }
      waiting.removeFirstOrNull().also { holder = it }
    }
    next?.granted?.complete(Unit)
  }
}
