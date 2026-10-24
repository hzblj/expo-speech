package com.hzblj.expospeech

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** The package's folders under the cache directory: transcripts, downloaded audio, recordings. */
class SpeechStorage(context: Context) {
  val root = File(context.cacheDir, "expo-speech")
  val transcripts = File(root, "transcripts")
  val audio = File(root, "audio")
  val recordings = File(root, "recordings")

  fun clear(transcripts: Boolean, audio: Boolean) {
    if (transcripts) this.transcripts.deleteRecursively()
    if (audio) this.audio.deleteRecursively()
  }

  companion object {
    fun hash(value: String): String =
      MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
  }
}

/** Finished transcripts on disk, keyed like `TranscriptCache` on iOS. */
class TranscriptCache(private val storage: SpeechStorage) {
  private fun file(key: String, locale: String, fingerprint: String) =
    File(storage.transcripts, SpeechStorage.hash(listOf(key, locale, "android", fingerprint).joinToString("\u001F")) + ".json")

  fun read(key: String, locale: String, fingerprint: String): Transcript? = try {
    val file = file(key, locale, fingerprint)
    if (file.exists()) Transcript.fromJson(JSONObject(file.readText())).let { it.copy(audioUri = relocated(it.audioUri)) } else null
  } catch (_: Exception) {
    null
  }

  /** The audio where it is now: a file of ours that moved is found again by its name; one that is gone leaves none. */
  private fun relocated(uri: String?): String? {
    val path = uri?.let { Uri.parse(it) }?.takeIf { it.scheme == "file" }?.path ?: return uri
    if (File(path).exists()) return uri
    val name = File(path).name
    return listOf(storage.audio, storage.recordings).map { File(it, name) }.firstOrNull { it.exists() }
      ?.let { Uri.fromFile(it).toString() }
  }

  fun write(transcript: Transcript, key: String, fingerprint: String) {
    try {
      storage.transcripts.mkdirs()
      val file = file(key, transcript.locale, fingerprint)
      val temporary = File(file.path + ".tmp")
      temporary.writeText(transcript.toJson().toString())
      temporary.renameTo(file)
    } catch (_: Exception) {
    }
  }
}

/**
 * Remote audio, downloaded once per URL and kept in the cache. Concurrent requests for one URL share the download,
 * which runs in a scope of its own: a request that is cancelled leaves without failing the others, and the download
 * stops when nobody waits for it any more.
 */
class AudioDownloads(private val context: Context, private val storage: SpeechStorage) {
  private class Shared(val download: Deferred<File>, val listeners: MutableList<(Double) -> Unit>, var waiters: Int)

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val pending = mutableMapOf<String, Shared>()

  /** A local file for `uri`: the file itself, a copy of a `content://` one, or the cached download of an http(s) one. */
  suspend fun localFile(uri: String, headers: Map<String, String>, progress: (Double) -> Unit): File {
    val parsed = Uri.parse(uri)
    when (parsed.scheme) {
      null, "file" -> return File(parsed.path ?: uri)
      "content" -> return withContext(Dispatchers.IO) { copyContent(parsed) }
      "http", "https" -> {}
      else -> throw SpeechFailure(SpeechFailure.AUDIO, "$uri is neither a file nor an http(s) URL")
    }

    val extension = parsed.lastPathSegment?.substringAfterLast('.', "")?.takeIf { it.length in 1..5 } ?: "audio"
    val destination = File(storage.audio, "${SpeechStorage.hash(uri)}.$extension")
    if (destination.exists()) {
      return destination
    }

    val shared = synchronized(this) {
      pending.getOrPut(uri) {
        val listeners = mutableListOf<(Double) -> Unit>()
        val download = scope.async {
          try {
            download(uri, headers, destination) { fraction ->
              synchronized(this@AudioDownloads) { listeners.toList() }.forEach { it(fraction) }
            }
          } finally {
            synchronized(this@AudioDownloads) { pending.remove(uri) }
          }
        }
        Shared(download, listeners, 0)
      }.also {
        it.waiters += 1
        it.listeners.add(progress)
      }
    }

    try {
      return shared.download.await()
    } finally {
      val orphaned = synchronized(this) {
        shared.waiters -= 1
        shared.listeners.remove(progress)
        shared.waiters == 0 && !shared.download.isCompleted
      }
      if (orphaned) {
        shared.download.cancel()
      }
    }
  }

  private suspend fun download(uri: String, headers: Map<String, String>, destination: File, progress: (Double) -> Unit): File {
    val connection = (URL(uri).openConnection() as HttpURLConnection).apply {
      connectTimeout = 15_000
      readTimeout = 30_000
      instanceFollowRedirects = true
      headers.forEach { (name, value) -> setRequestProperty(name, value) }
    }
    val temporary = File(destination.path + ".part")
    try {
      val status = connection.responseCode
      if (status !in 200..299) {
        throw SpeechFailure(SpeechFailure.NETWORK, "The download failed with HTTP $status")
      }
      val total = connection.contentLengthLong
      storage.audio.mkdirs()
      connection.inputStream.use { input ->
        temporary.outputStream().use { output ->
          val buffer = ByteArray(64 * 1024)
          var written = 0L
          while (true) {
            // Nobody waits any more: stop between reads.
            coroutineContext.ensureActive()
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
            written += read
            if (total > 0) {
              progress(written.toDouble() / total)
            }
          }
        }
      }
      if (!temporary.renameTo(destination)) {
        throw SpeechFailure(SpeechFailure.AUDIO, "The download could not be saved")
      }
      return destination
    } catch (error: SpeechFailure) {
      throw error
    } catch (error: kotlinx.coroutines.CancellationException) {
      temporary.delete()
      throw error
    } catch (error: Exception) {
      throw SpeechFailure(SpeechFailure.NETWORK, error.message ?: "The download failed", error)
    } finally {
      connection.disconnect()
    }
  }

  private fun copyContent(uri: Uri): File {
    val destination = File(storage.audio, SpeechStorage.hash(uri.toString()))
    storage.audio.mkdirs()
    context.contentResolver.openInputStream(uri)?.use { input ->
      destination.outputStream().use { input.copyTo(it) }
    } ?: throw SpeechFailure(SpeechFailure.AUDIO, "$uri could not be opened")
    return destination
  }
}
