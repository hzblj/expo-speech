import CryptoKit
import Foundation

/// The package's folders under Caches: finished transcripts, downloaded audio, recordings and custom models.
public enum SpeechStorage {
  public static var root: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("expo-speech")
  }

  public static var transcripts: URL { root.appendingPathComponent("transcripts") }
  public static var audio: URL { root.appendingPathComponent("audio") }
  public static var recordings: URL { root.appendingPathComponent("recordings") }
  public static var models: URL { root.appendingPathComponent("models") }

  static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public static func clear(transcripts clearTranscripts: Bool, audio clearAudio: Bool) {
    if clearTranscripts {
      try? FileManager.default.removeItem(at: transcripts)
    }
    if clearAudio {
      try? FileManager.default.removeItem(at: audio)
    }
  }
}

/// Finished transcripts on disk, keyed by the caller's key, the locale, the engine and the options they depend on.
public enum TranscriptCache {
  static func url(key: String, locale: String, engine: String, fingerprint: String) -> URL {
    SpeechStorage.transcripts.appendingPathComponent(
      SpeechStorage.hash([key, locale, engine, fingerprint].joined(separator: "\u{1F}")) + ".json")
  }

  public static func read(key: String, locale: String, engine: String, fingerprint: String) -> Transcript? {
    guard
      let data = try? Data(contentsOf: url(key: key, locale: locale, engine: engine, fingerprint: fingerprint)),
      var transcript = try? JSONDecoder().decode(Transcript.self, from: data)
    else {
      return nil
    }
    transcript.audioUri = relocated(transcript.audioUri)
    return transcript
  }

  /// The audio in today's container: an update or a reinstall moves the app's container, and with it every absolute
  /// path the cache wrote. A file of ours is found again by its name; one that is gone leaves no `audioUri`.
  static func relocated(_ uri: String?) -> String? {
    guard let uri, let url = URL(string: uri), url.isFileURL else {
      return uri
    }
    if FileManager.default.fileExists(atPath: url.path) {
      return uri
    }
    for folder in [SpeechStorage.audio, SpeechStorage.recordings] {
      let candidate = folder.appendingPathComponent(url.lastPathComponent)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate.absoluteString
      }
    }
    return nil
  }

  public static func write(_ transcript: Transcript, key: String, engine: String, fingerprint: String) {
    let url = url(key: key, locale: transcript.locale, engine: engine, fingerprint: fingerprint)
    try? FileManager.default.createDirectory(at: SpeechStorage.transcripts, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(transcript) {
      try? data.write(to: url, options: .atomic)
    }
  }
}

/// Remote audio, downloaded once per URL and kept in Caches. Concurrent requests for one URL share the download.
public final class AudioDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  public static let shared = AudioDownloads()

  private struct Pending {
    var destination: URL
    var continuations: [CheckedContinuation<URL, Error>]
    var progress: [(Double) -> Void]
  }

  private let lock = NSLock()
  private var pending: [String: Pending] = [:]
  private var tasks: [Int: String] = [:]
  private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

  /// A local file for `url`: itself when it is one, the cached download otherwise.
  public func localFile(
    for url: URL, headers: [String: String], progress: @escaping (Double) -> Void
  ) async throws -> URL {
    if url.isFileURL {
      return url
    }
    guard url.scheme == "http" || url.scheme == "https" else {
      throw SpeechFailure(.audio, "\(url.absoluteString) is neither a file nor an http(s) URL")
    }

    let key = url.absoluteString
    let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
    let destination = SpeechStorage.audio.appendingPathComponent("\(SpeechStorage.hash(key)).\(ext)")

    if FileManager.default.fileExists(atPath: destination.path) {
      return destination
    }

    return try await withCheckedThrowingContinuation { continuation in
      let start = lock.withLock { () -> Bool in
        if var existing = pending[key] {
          existing.continuations.append(continuation)
          existing.progress.append(progress)
          pending[key] = existing
          return false
        }
        pending[key] = Pending(destination: destination, continuations: [continuation], progress: [progress])
        return true
      }

      guard start else {
        return
      }

      var request = URLRequest(url: url)
      for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
      }
      let task = session.downloadTask(with: request)
      lock.withLock { tasks[task.taskIdentifier] = key }
      task.resume()
    }
  }

  private func finish(_ task: URLSessionTask, with result: Result<URL, Error>) {
    let entry = lock.withLock { () -> Pending? in
      guard let key = tasks.removeValue(forKey: task.taskIdentifier) else {
        return nil
      }
      return pending.removeValue(forKey: key)
    }
    for continuation in entry?.continuations ?? [] {
      continuation.resume(with: result)
    }
  }

  public func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else {
      return
    }
    let callbacks = lock.withLock { () -> [(Double) -> Void] in
      guard let key = tasks[downloadTask.taskIdentifier] else {
        return []
      }
      return pending[key]?.progress ?? []
    }
    let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    for callback in callbacks {
      callback(fraction)
    }
  }

  public func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    let destination = lock.withLock { () -> URL? in
      tasks[downloadTask.taskIdentifier].flatMap { pending[$0]?.destination }
    }
    guard let destination else {
      return
    }

    if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
      finish(downloadTask, with: .failure(SpeechFailure(.network, "The download failed with HTTP \(response.statusCode)")))
      return
    }

    do {
      try FileManager.default.createDirectory(at: SpeechStorage.audio, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: destination)
      // The temporary file is gone once this returns: move it now.
      try FileManager.default.moveItem(at: location, to: destination)
      finish(downloadTask, with: .success(destination))
    } catch {
      finish(downloadTask, with: .failure(SpeechFailure(.audio, "The download could not be saved: \(error.localizedDescription)")))
    }
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      finish(task, with: .failure(SpeechFailure(.network, error.localizedDescription)))
    }
  }
}
