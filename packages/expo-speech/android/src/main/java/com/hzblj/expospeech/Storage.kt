package com.hzblj.expospeech

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
    if (file.exists()) Transcript.fromJson(JSONObject(file.readText())) else null
  } catch (_: Exception) {
    null
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

/** Remote audio, downloaded once per URL and kept in the cache. Concurrent requests for one URL share the download. */
class AudioDownloads(private val context: Context, private val storage: SpeechStorage) {
  private val pending = mutableMapOf<String, CompletableDeferred<File>>()
  private val listeners = mutableMapOf<String, MutableList<(Double) -> Unit>>()

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

    val (deferred, starts) = synchronized(this) {
      listeners.getOrPut(uri) { mutableListOf() }.add(progress)
      val existing = pending[uri]
      if (existing != null) existing to false else CompletableDeferred<File>().also { pending[uri] = it } to true
    }

    if (starts) {
      try {
        val file = withContext(Dispatchers.IO) { download(uri, headers, destination) }
        deferred.complete(file)
      } catch (error: Throwable) {
        deferred.completeExceptionally(error)
      } finally {
        synchronized(this) {
          pending.remove(uri)
          listeners.remove(uri)
        }
      }
    }
    return deferred.await()
  }

  private fun download(uri: String, headers: Map<String, String>, destination: File): File {
    val connection = (URL(uri).openConnection() as HttpURLConnection).apply {
      connectTimeout = 15_000
      readTimeout = 30_000
      instanceFollowRedirects = true
      headers.forEach { (name, value) -> setRequestProperty(name, value) }
    }
    try {
      val status = connection.responseCode
      if (status !in 200..299) {
        throw SpeechFailure(SpeechFailure.NETWORK, "The download failed with HTTP $status")
      }
      val total = connection.contentLengthLong
      storage.audio.mkdirs()
      val temporary = File(destination.path + ".part")
      connection.inputStream.use { input ->
        temporary.outputStream().use { output ->
          val buffer = ByteArray(64 * 1024)
          var written = 0L
          while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
            written += read
            if (total > 0) {
              val fraction = written.toDouble() / total
              synchronized(this) { listeners[uri]?.toList() }?.forEach { it(fraction) }
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
