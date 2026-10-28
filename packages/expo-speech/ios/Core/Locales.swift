import Foundation
import Speech

/// Which locales the engine can transcribe, which are installed, and installing them. iOS 26 asks `AssetInventory`
/// about the transcriber module for the mode; before it, `SFSpeechRecognizer` has no downloads: a locale is
/// installed when it can be recognized as asked (on the device, or at all).
public enum SpeechLocales {
  public static func supported(_ options: LocaleOptions) async -> [String] {
    if #available(iOS 26.0, macOS 26.0, *) {
      let locales =
        options.mode == .dictation || !SpeechTranscriber.isAvailable
        ? await DictationTranscriber.supportedLocales
        : await SpeechTranscriber.supportedLocales
      return locales.map(\.bcp47).sorted()
    }
    return SFSpeechRecognizer.supportedLocales().map(\.bcp47).sorted()
  }

  public static func installed(_ options: LocaleOptions) async -> [String] {
    if #available(iOS 26.0, macOS 26.0, *) {
      let locales =
        options.mode == .dictation || !SpeechTranscriber.isAvailable
        ? await DictationTranscriber.installedLocales
        : await SpeechTranscriber.installedLocales
      return locales.map(\.bcp47).sorted()
    }
    return SFSpeechRecognizer.supportedLocales()
      .filter { !options.onDevice || SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
      .map(\.bcp47)
      .sorted()
  }

  private static func engineOptions(_ locale: String, _ options: LocaleOptions) -> TranscriberOptions {
    var transcriber = TranscriberOptions()
    transcriber.locale = locale
    transcriber.mode = options.mode
    transcriber.onDevice = options.onDevice ? .required : .off
    return transcriber
  }

  /// `unsupported`, `supported`, `downloading` or `installed`.
  public static func status(_ locale: String, _ options: LocaleOptions) async -> String {
    if #available(iOS 26.0, macOS 26.0, *) {
      guard let engine = try? await AnalyzerEngine.make(engineOptions(locale, options)) else {
        return "unsupported"
      }
      switch await AssetInventory.status(forModules: [engine.makeModules().0.module]) {
      case .installed: return "installed"
      case .downloading: return "downloading"
      case .supported: return "supported"
      default: return "unsupported"
      }
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
      return "unsupported"
    }
    return !options.onDevice || recognizer.supportsOnDeviceRecognition ? "installed" : "unsupported"
  }

  /// Installs the locale's model, reporting progress from 0 to 1.
  public static func install(_ locale: String, _ options: LocaleOptions, progress: @escaping (Double) -> Void) async throws {
    if #available(iOS 26.0, macOS 26.0, *) {
      let engine = try await AnalyzerEngine.make(engineOptions(locale, options))
      try await AnalyzerEngine.ensureAssets(
        for: [engine.makeModules().0.module], download: true, sink: ProgressSink(progress))
      progress(1)
      return
    }
    if await status(locale, options) != "installed" {
      throw SpeechFailure(.unsupported, "\(locale) cannot be installed: the speech recognizer before iOS 26 has no downloads")
    }
    progress(1)
  }

  public static func reserved() async -> [String] {
    if #available(iOS 26.0, macOS 26.0, *) {
      return await AssetInventory.reservedLocales.map(\.bcp47)
    }
    return []
  }

  public static var maximumReserved: Int {
    if #available(iOS 26.0, macOS 26.0, *) {
      return AssetInventory.maximumReservedLocales
    }
    return 0
  }

  public static func reserve(_ locale: String) async throws -> Bool {
    if #available(iOS 26.0, macOS 26.0, *) {
      do {
        return try await AssetInventory.reserve(locale: Locale(identifier: locale))
      } catch {
        throw SpeechFailure(.localeUnavailable, error.localizedDescription)
      }
    }
    return false
  }

  public static func release(_ locale: String) async -> Bool {
    if #available(iOS 26.0, macOS 26.0, *) {
      return await AssetInventory.release(reservedLocale: Locale(identifier: locale))
    }
    return false
  }

  public static func endRetention() async {
    if #available(iOS 26.0, macOS 26.0, *) {
      await SpeechModels.endRetention()
    }
  }
}

/// Forwards only the installing phase to a closure.
private final class ProgressSink: EngineSink, @unchecked Sendable {
  private let progress: (Double) -> Void

  init(_ progress: @escaping (Double) -> Void) {
    self.progress = progress
  }

  func engine(recognized result: RecognizedResult) {}
  func engine(detectedSpeech detected: Bool, at time: Double) {}
  func engine(progress fraction: Double, phase: String) {
    progress(fraction)
  }
}

/// Custom language models (iOS 17): built from the app's phrases, templates and pronunciations, exported and
/// compiled once per identifier and version.
public enum CustomLanguageModels {
  public static func prepare(_ data: CustomLanguageModelData) async throws -> CustomLanguageModelReference {
    guard #available(iOS 17.0, macOS 14.0, *) else {
      throw SpeechFailure(.unsupported, "Custom language models need iOS 17")
    }

    let directory = SpeechStorage.models.appendingPathComponent(
      SpeechStorage.hash("\(data.identifier)\u{1F}\(data.version)\u{1F}\(data.locale)"))
    let asset = directory.appendingPathComponent("data.bin")
    let languageModel = directory.appendingPathComponent("lm")
    let vocabulary = directory.appendingPathComponent("vocabulary")
    let reference = CustomLanguageModelReference(
      languageModel: languageModel.absoluteString, vocabulary: vocabulary.absoluteString, weight: data.weight)

    if FileManager.default.fileExists(atPath: languageModel.path) {
      return reference
    }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let model = SFCustomLanguageModelData(
      locale: Locale(identifier: data.locale), identifier: data.identifier, version: data.version)

    for phrase in data.phrases ?? [] {
      model.insert(phraseCount: .init(phrase: phrase.phrase, count: phrase.count))
    }
    for pronunciation in data.pronunciations ?? [] {
      model.insert(term: .init(grapheme: pronunciation.grapheme, phonemes: pronunciation.phonemes))
    }
    if let templates = data.templates {
      let generator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
      for (name, values) in templates.classes {
        generator.define(className: name, values: values)
      }
      for template in templates.templates {
        generator.insert(template: template.body, count: template.count)
      }
      model.insert(phraseCountGenerator: generator)
    }

    do {
      try await model.export(to: asset)
      let configuration = SFSpeechLanguageModel.Configuration(languageModel: languageModel, vocabulary: vocabulary)
      try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: configuration)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw SpeechFailure(.service, "The custom language model could not be prepared: \(error.localizedDescription)")
    }
    return reference
  }
}
