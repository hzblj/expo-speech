import Foundation

/// `SpeechTranscriberOptions` from `src/types.ts`, decoded from JavaScript. Defaults are the documented ones.
public struct TranscriberOptions: Decodable, Sendable, Equatable {
  public enum Mode: String, Decodable, Sendable { case transcription, dictation }
  public enum OnDevice: String, Decodable, Sendable { case required, preferred, off }

  public var locale: String?
  public var mode: Mode = .transcription
  public var onDevice: OnDevice = .required
  public var contextualStrings: [String] = []
  public var punctuation = true
  public var volatileResults = true
  public var alternatives = false
  public var maskOffensiveWords: Bool?
  /// `nil` when off, otherwise the sensitivity.
  public var detectSpeech: String?
  public var maxConcurrent = 1
  public var ios = IOS()

  public struct IOS: Decodable, Sendable, Equatable {
    public enum Engine: String, Decodable, Sendable { case auto, analyzer, recognizer }

    public var engine: Engine = .auto
    public var fastResults = false
    public var contentHints: [String] = []
    public var emoji = false
    public var frequentFinalization = false
    public var taskHint: String?
    public var customLanguageModel: CustomLanguageModelReference?
    public var modelRetention = "lingering"
    public var priority = "userInitiated"
    public var ignoresResourceLimits = false

    public init() {}

    enum CodingKeys: String, CodingKey {
      case engine, fastResults, contentHints, emoji, frequentFinalization, taskHint, customLanguageModel,
        modelRetention, priority, ignoresResourceLimits
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      engine = try container.decodeIfPresent(Engine.self, forKey: .engine) ?? .auto
      fastResults = try container.decodeIfPresent(Bool.self, forKey: .fastResults) ?? false
      contentHints = try container.decodeIfPresent([String].self, forKey: .contentHints) ?? []
      emoji = try container.decodeIfPresent(Bool.self, forKey: .emoji) ?? false
      frequentFinalization = try container.decodeIfPresent(Bool.self, forKey: .frequentFinalization) ?? false
      taskHint = try container.decodeIfPresent(String.self, forKey: .taskHint)
      customLanguageModel = try container.decodeIfPresent(
        CustomLanguageModelReference.self, forKey: .customLanguageModel)
      modelRetention = try container.decodeIfPresent(String.self, forKey: .modelRetention) ?? "lingering"
      priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "userInitiated"
      ignoresResourceLimits = try container.decodeIfPresent(Bool.self, forKey: .ignoresResourceLimits) ?? false
    }
  }

  public init() {}

  enum CodingKeys: String, CodingKey {
    case locale, mode, onDevice, contextualStrings, punctuation, volatileResults, alternatives, maskOffensiveWords,
      detectSpeech, maxConcurrent, ios
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    locale = try container.decodeIfPresent(String.self, forKey: .locale)
    mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .transcription
    onDevice = try container.decodeIfPresent(OnDevice.self, forKey: .onDevice) ?? .required
    contextualStrings = try container.decodeIfPresent([String].self, forKey: .contextualStrings) ?? []
    punctuation = try container.decodeIfPresent(Bool.self, forKey: .punctuation) ?? true
    volatileResults = try container.decodeIfPresent(Bool.self, forKey: .volatileResults) ?? true
    alternatives = try container.decodeIfPresent(Bool.self, forKey: .alternatives) ?? false
    maskOffensiveWords = try container.decodeIfPresent(Bool.self, forKey: .maskOffensiveWords)
    // `true` or a sensitivity.
    if let sensitivity = try? container.decodeIfPresent(String.self, forKey: .detectSpeech) {
      detectSpeech = sensitivity
    } else if let enabled = try? container.decodeIfPresent(Bool.self, forKey: .detectSpeech), enabled {
      detectSpeech = "medium"
    }
    maxConcurrent = max(1, try container.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 1)
    ios = try container.decodeIfPresent(IOS.self, forKey: .ios) ?? IOS()
  }

  /// What a cached transcript depends on, besides the audio and the locale.
  public var fingerprint: String {
    [
      mode.rawValue, punctuation ? "p" : "", alternatives ? "a" : "", maskOffensiveWords == true ? "m" : "",
      ios.engine.rawValue, ios.emoji ? "e" : "", ios.contentHints.sorted().joined(separator: ","),
      contextualStrings.joined(separator: "|"), onDevice.rawValue, ios.taskHint ?? "",
      ios.customLanguageModel.map { "\($0.languageModel)|\($0.vocabulary ?? "")|\($0.weight ?? -1)" } ?? "",
    ].joined(separator: ";")
  }
}

public struct CustomLanguageModelReference: Codable, Sendable, Equatable {
  public var languageModel: String
  public var vocabulary: String?
  public var weight: Double?
}

/// `TranscribeOptions` from `src/types.ts`.
public struct TranscribeOptions: Decodable, Sendable {
  public var cacheKey: String?
  public var priority = "normal"
  public var range: TimeRangeOption?
  public var headers: [String: String] = [:]

  public struct TimeRangeOption: Decodable, Sendable {
    public var start: Double?
    public var end: Double?
  }

  public init() {}

  enum CodingKeys: String, CodingKey { case cacheKey, priority, range, headers }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cacheKey = try container.decodeIfPresent(String.self, forKey: .cacheKey)
    priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "normal"
    range = try container.decodeIfPresent(TimeRangeOption.self, forKey: .range)
    headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
  }
}

/// `ListenOptions` from `src/types.ts`.
public struct ListenOptions: Decodable, Sendable {
  public var record = false
  public var volumeInterval: Double = 0
  /// Seconds; `nil` when off.
  public var stopAfterSilence: Double?
  /// Seconds; `nil` when off.
  public var stopWithoutSpeech: Double?
  public var voiceProcessing = false
  public var audioSession = "auto"

  public init() {}

  enum CodingKeys: String, CodingKey { case record, volumeInterval, autoStop, voiceProcessing, ios }
  enum AutoStopKeys: String, CodingKey { case afterSilence, withoutSpeech }
  enum IOSKeys: String, CodingKey { case audioSession }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    record = try container.decodeIfPresent(Bool.self, forKey: .record) ?? false
    volumeInterval = try container.decodeIfPresent(Double.self, forKey: .volumeInterval) ?? 0
    if container.contains(.autoStop),
      let autoStop = try? container.nestedContainer(keyedBy: AutoStopKeys.self, forKey: .autoStop)
    {
      stopAfterSilence = try autoStop.decodeIfPresent(Double.self, forKey: .afterSilence).map { $0 / 1000 }
      stopWithoutSpeech = try autoStop.decodeIfPresent(Double.self, forKey: .withoutSpeech).map { $0 / 1000 }
    }
    voiceProcessing = try container.decodeIfPresent(Bool.self, forKey: .voiceProcessing) ?? false
    if container.contains(.ios), let ios = try? container.nestedContainer(keyedBy: IOSKeys.self, forKey: .ios) {
      audioSession = try ios.decodeIfPresent(String.self, forKey: .audioSession) ?? "auto"
    }
  }
}

/// `CustomLanguageModelData` from `src/types.ts`.
public struct CustomLanguageModelData: Decodable, Sendable {
  public struct Phrase: Decodable, Sendable {
    public var phrase: String
    public var count: Int
  }

  public struct Pronunciation: Decodable, Sendable {
    public var grapheme: String
    public var phonemes: [String]
  }

  public struct Templates: Decodable, Sendable {
    public struct Template: Decodable, Sendable {
      public var body: String
      public var count: Int
    }

    public var classes: [String: [String]]
    public var templates: [Template]
  }

  public var locale: String
  public var identifier: String
  public var version: String
  public var phrases: [Phrase]?
  public var pronunciations: [Pronunciation]?
  public var templates: Templates?
  public var weight: Double?
}

/// `LocaleOptions` from `src/types.ts`.
public struct LocaleOptions: Decodable, Sendable {
  public var mode: TranscriberOptions.Mode = .transcription
  public var onDevice = true

  public init() {}

  enum CodingKeys: String, CodingKey { case mode, onDevice }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decodeIfPresent(TranscriberOptions.Mode.self, forKey: .mode) ?? .transcription
    onDevice = try container.decodeIfPresent(Bool.self, forKey: .onDevice) ?? true
  }
}
