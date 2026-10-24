package com.hzblj.expospeech

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections

class SessionGateTest {
  @Test
  fun theMicrophoneGoesBeforeWaitingFilesAndAFileMakesWay() = runBlocking {
    val order = Collections.synchronizedList(mutableListOf<String>())
    val preempted = CompletableDeferred<Unit>()
    val running = CompletableDeferred<Unit>()

    val first = async {
      SessionGate.use(microphone = false) { turn ->
        SessionGate.onPreempt(turn) { preempted.complete(Unit) }
        running.complete(Unit)
        order.add("file 1")
        // A session that runs until it is asked to make way.
        withTimeout(2_000) { preempted.await() }
        order.add("file 1 made way")
      }
    }
    running.await()

    val second = launch { SessionGate.use(microphone = false) { order.add("file 2") } }
    delay(50)
    val microphone = launch { SessionGate.use(microphone = true) { order.add("microphone") } }

    first.await()
    second.join()
    microphone.join()

    assertEquals(listOf("file 1", "file 1 made way", "microphone", "file 2"), order)
  }

  @Test
  fun aFileThatStartsWhileTheMicrophoneWaitsMakesWayAtOnce() = runBlocking {
    val holding = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    val microphoneHolder = launch {
      SessionGate.use(microphone = true) {
        holding.complete(Unit)
        release.await()
      }
    }
    holding.await()

    var asked = false
    val file = launch {
      SessionGate.use(microphone = false) { turn -> SessionGate.onPreempt(turn) { asked = true } }
    }
    val waitingMicrophone = launch { SessionGate.use(microphone = true) {} }
    delay(50)
    release.complete(Unit)
    microphoneHolder.join()
    waitingMicrophone.join()
    file.join()

    // The second microphone went before the file, so the file found nobody waiting.
    assertEquals(false, asked)
  }

  @Test
  fun aCancelledWaiterPassesItsTurnOn() = runBlocking {
    val holding = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()
    val holder = launch {
      SessionGate.use(microphone = false) {
        holding.complete(Unit)
        release.await()
      }
    }
    holding.await()

    val cancelled = launch { SessionGate.use(microphone = false) { error("never") } }
    var ran = false
    val next = launch { SessionGate.use(microphone = false) { ran = true } }
    delay(20)
    cancelled.cancel()
    release.complete(Unit)
    holder.join()
    next.join()

    assertTrue(ran)
  }
}
