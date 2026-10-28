import AVFoundation
import ExpoModulesCore
import Speech

/// Options arrive as plain objects and are decoded into the Core's `Decodable` structs, which hold the defaults.
private func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]?) throws -> T {
  do {
    let data = try JSONSerialization.data(withJSONObject: value ?? [:])
    return try JSONDecoder().decode(T.self, from: data)
  } catch {
    throw SpeechException(SpeechFailure(.unknown, "Invalid options: \(error.localizedDescription)"))
  }
}

/// Runs a Core call, turning its failures into JavaScript errors with a `code`.
private func bridging<T>(_ body: () async throws -> T) async throws -> T {
  do {
    return try await body()
  } catch let exception as Exception {
    throw exception
  } catch {
    throw SpeechException(SpeechFailure.from(error))
  }
}

public final class ExpoSpeechModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoSpeech")

    Events("installProgress")

    AsyncFunction("getPermissionsAsync") { (microphone: Bool, speechRecognition: Bool?) -> [String: Any] in
      Permissions.response(microphone: microphone, speechRecognition: speechRecognition ?? Permissions.speechNeeded)
    }

    AsyncFunction("requestPermissionsAsync") { (microphone: Bool, speechRecognition: Bool?) async -> [String: Any] in
      await Permissions.request(microphone: microphone, speechRecognition: speechRecognition ?? Permissions.speechNeeded)
    }

    AsyncFunction("getAvailabilityAsync") { (options: [String: Any]) async throws -> [String: Any] in
      let localeOptions = try decode(LocaleOptions.self, options)
      return await Availability.current(localeOptions)
    }

    AsyncFunction("getSupportedLocalesAsync") { (options: [String: Any]) async throws -> [String] in
      await SpeechLocales.supported(try decode(LocaleOptions.self, options))
    }

    AsyncFunction("getInstalledLocalesAsync") { (options: [String: Any]) async throws -> [String] in
      await SpeechLocales.installed(try decode(LocaleOptions.self, options))
    }

    AsyncFunction("getLocaleStatusAsync") { (locale: String, options: [String: Any]) async throws -> String in
      await SpeechLocales.status(locale, try decode(LocaleOptions.self, options))
    }

    AsyncFunction("installLocaleAsync") { (locale: String, options: [String: Any]) async throws in
      let localeOptions = try decode(LocaleOptions.self, options)
      try await bridging {
        try await SpeechLocales.install(locale, localeOptions) { [weak self] fraction in
          self?.sendEvent(
            "installProgress", ["locale": locale, "mode": localeOptions.mode.rawValue, "fraction": fraction])
        }
      }
    }

    AsyncFunction("getReservedLocalesAsync") { () async -> [String] in
      await SpeechLocales.reserved()
    }

    AsyncFunction("reserveLocaleAsync") { (locale: String) async throws -> Bool in
      try await bridging { try await SpeechLocales.reserve(locale) }
    }

    AsyncFunction("releaseLocaleAsync") { (locale: String) async -> Bool in
      await SpeechLocales.release(locale)
    }

    Constant("maximumReservedLocales") { () -> Int in
      SpeechLocales.maximumReserved
    }

    AsyncFunction("endModelRetentionAsync") { () async in
      await SpeechLocales.endRetention()
    }

    AsyncFunction("prepareCustomLanguageModelAsync") { (data: [String: Any]) async throws -> [String: Any] in
      let modelData = try decode(CustomLanguageModelData.self, data)
      let reference = try await bridging { try await CustomLanguageModels.prepare(modelData) }
      return [
        "languageModel": reference.languageModel,
        "vocabulary": reference.vocabulary.map { $0 as Any } ?? NSNull(),
        "weight": reference.weight.map { $0 as Any } ?? NSNull(),
      ]
    }

    AsyncFunction("clearCacheAsync") { (options: [String: Any]) in
      SpeechStorage.clear(
        transcripts: options["transcripts"] as? Bool ?? true, audio: options["audio"] as? Bool ?? true)
    }

    Class("SpeechTranscriber", SpeechTranscriberObject.self) {
      Constructor { (options: [String: Any]?) throws -> SpeechTranscriberObject in
        SpeechTranscriberObject(options: try decode(TranscriberOptions.self, options))
      }

      Property("locale") { (transcriber: SpeechTranscriberObject) -> String in
        transcriber.locale
      }

      Property("engine") { (transcriber: SpeechTranscriberObject) -> String in
        transcriber.engineName
      }

      Property("pending") { (transcriber: SpeechTranscriberObject) -> Int in
        transcriber.pending
      }

      AsyncFunction("prepareAsync") { (transcriber: SpeechTranscriberObject, options: [String: Any]?) async throws in
        let download = options?["download"] as? Bool ?? false
        try await bridging { try await transcriber.prepare(download: download) }
      }

      Function("transcribeUri") {
        (transcriber: SpeechTranscriberObject, uri: String, options: [String: Any]?) throws -> TranscriptionObject in
        transcriber.transcribe(uri: uri, options: try decode(TranscribeOptions.self, options))
      }

      Function("listen") {
        (transcriber: SpeechTranscriberObject, options: [String: Any]?) throws -> TranscriptionObject in
        try transcriber.listen(options: try decode(ListenOptions.self, options))
      }

      Function("cancelAll") { (transcriber: SpeechTranscriberObject) in
        transcriber.cancelAll()
      }
    }

    Class("Transcription", TranscriptionObject.self) {
      Property("id") { (transcription: TranscriptionObject) -> String in
        transcription.id
      }

      Property("kind") { (transcription: TranscriptionObject) -> String in
        transcription.kind.rawValue
      }

      Property("state") { (transcription: TranscriptionObject) -> String in
        transcription.state.rawValue
      }

      Property("cacheKey") { (transcription: TranscriptionObject) -> String? in
        transcription.cacheKey
      }

      Property("fromCache") { (transcription: TranscriptionObject) -> Bool in
        transcription.fromCache
      }

      Property("progress") { (transcription: TranscriptionObject) -> Double in
        transcription.progress
      }

      Property("transcript") { (transcription: TranscriptionObject) -> [String: Any] in
        transcription.transcript.json
      }

      Property("error") { (transcription: TranscriptionObject) -> [String: Any]? in
        transcription.failure?.json
      }

      AsyncFunction("wait") { (transcription: TranscriptionObject, promise: Promise) in
        transcription.wait(promise)
      }

      Function("stop") { (transcription: TranscriptionObject) in
        transcription.stop()
      }

      Function("pause") { (transcription: TranscriptionObject) in
        transcription.pause()
      }

      Function("resume") { (transcription: TranscriptionObject) in
        transcription.resume()
      }

      Function("cancel") { (transcription: TranscriptionObject) in
        transcription.cancel()
      }
    }
  }
}

/// What the engine can do on this device.
enum Availability {
  static func current(_ options: LocaleOptions) async -> [String: Any] {
    if #available(iOS 26.0, *) {
      return [
        "engine": "analyzer",
        "available": true,
        "transcriber": SpeechTranscriber.isAvailable,
        "dictation": true,
        "onDevice": true,
        "fileTranscription": true,
        "wordTiming": true,
        "languageDetection": false,
      ]
    }
    let recognizer = SFSpeechRecognizer()
    return [
      "engine": "recognizer",
      "available": recognizer?.isAvailable ?? false,
      "transcriber": false,
      "dictation": false,
      "onDevice": recognizer?.supportsOnDeviceRecognition ?? false,
      "fileTranscription": true,
      "wordTiming": true,
      "languageDetection": false,
    ]
  }
}

/// Speech recognition and the microphone, in the shape of Expo's permission responses.
enum Permissions {
  private static func speechStatus() -> String {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return "granted"
    case .notDetermined: return "undetermined"
    default: return "denied"
    }
  }

  static var microphoneDenied: Bool {
    microphoneStatus() == "denied"
  }

  private static func microphoneStatus() -> String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return "granted"
      case .denied: return "denied"
      default: return "undetermined"
      }
    }
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted: return "granted"
    case .denied: return "denied"
    default: return "undetermined"
    }
  }

  /** Speech recognition authorization is `SFSpeechRecognizer`'s: SpeechAnalyzer (iOS 26) runs without it. */
  static var speechNeeded: Bool {
    !SpeechEngines.analyzerAvailable
  }

  static func response(microphone: Bool, speechRecognition: Bool) -> [String: Any] {
    let speech = speechStatus()
    let mic = microphoneStatus()
    let statuses = (speechRecognition ? [speech] : []) + (microphone ? [mic] : [])
    let status =
      statuses.contains("denied") ? "denied" : statuses.allSatisfy { $0 == "granted" } ? "granted" : "undetermined"

    return [
      "status": status,
      "granted": status == "granted",
      "canAskAgain": !statuses.contains("denied"),
      "expires": "never",
      "speechRecognition": speech,
      "microphone": mic,
    ]
  }

  static func request(microphone: Bool, speechRecognition: Bool) async -> [String: Any] {
    if speechRecognition, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
      }
    }
    if microphone, microphoneStatus() == "undetermined" {
      if #available(iOS 17.0, *) {
        _ = await AVAudioApplication.requestRecordPermission()
      } else {
        await withCheckedContinuation { continuation in
          AVAudioSession.sharedInstance().requestRecordPermission { _ in continuation.resume() }
        }
      }
    }
    return response(microphone: microphone, speechRecognition: speechRecognition)
  }
}
