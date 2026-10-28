/**
 * A word as the recognizer heard it, with the punctuation that hangs on it ("box," or "lap.").
 */
export type TranscriptWord = {
  /** The word without surrounding whitespace, punctuation attached. */
  text: string
  /** Seconds from the start of the audio where the word begins. */
  start: number
  /** Seconds from the start of the audio where the word ends. */
  end: number
  /** UTF-16 offsets of `text` in `Transcript.text`: `transcript.text.slice(range[0], range[1]) === word.text`. */
  range: [number, number]
  /** How sure the recognizer is, from 0 to 1, or `null` when the platform does not say. */
  confidence: number | null
  /**
   * `measured` when the platform timed the word itself. `estimated` when it timed only a longer stretch (a phrase, a
   * result still being revised, or Android before 14) and the word got its share of it by length.
   */
  timing: 'measured' | 'estimated'
}

/**
 * One result of the recognizer: a stretch of audio and its text. Final segments never change again; the last segment
 * of a running transcription may be volatile (`isFinal: false`) and is replaced as the recognizer revises it.
 */
export type TranscriptSegment = {
  /** The text as the recognizer wrote it, spacing included, so the segments concatenate to `Transcript.text`. */
  text: string
  /** Seconds from the start of the audio. */
  start: number
  /** Seconds from the start of the audio. */
  end: number
  /** UTF-16 offsets of `text` in `Transcript.text`. */
  range: [number, number]
  /** `false` while the recognizer may still change it. */
  isFinal: boolean
  /** The mean confidence of its words, from 0 to 1, or `null` when the platform does not say. */
  confidence: number | null
  /** Other readings of the whole segment, most likely first, when `alternatives` was asked for. */
  alternatives: string[]
  words: TranscriptWord[]
  /** The language the recognizer detected for this segment (Android's language detection), as a BCP 47 tag. */
  language: string | null
}

/**
 * Everything recognized so far: final segments and, while a transcription runs, a volatile one at the end.
 */
export type Transcript = {
  /** The whole text, volatile tail included. */
  text: string
  /** The locale the audio was transcribed in, as a BCP 47 tag (`en-GB`). */
  locale: string
  segments: TranscriptSegment[]
  /** Every word of every segment, in order. */
  words: TranscriptWord[]
  /** The length of the audio in seconds, when known (files, and recordings once stopped). */
  duration: number | null
  /** The local file that was transcribed: the downloaded copy of a remote source, or the recording of `listen`. */
  audioUri: string | null
}

/** What the platform transcribes with. */
export type SpeechEngine =
  /** iOS 26 and later: `SpeechAnalyzer` with `SpeechTranscriber` or `DictationTranscriber`. */
  | 'analyzer'
  /** iOS before 26, or forced with `ios.engine`: `SFSpeechRecognizer`. */
  | 'recognizer'
  /** Android: `android.speech.SpeechRecognizer`. */
  | 'android'

/**
 * - `transcription`: general speech to text, made for recordings, conversations and long audio.
 * - `dictation`: speech the user means as text, with spoken punctuation and contextual strings honoured.
 */
export type SpeechMode = 'transcription' | 'dictation'

/** Where the audio is recognized: see `SpeechTranscriberOptions.onDevice`. */
export type OnDevice = 'required' | 'preferred' | 'off'

export type SpeechTranscriberOptions = {
  /** A BCP 47 tag (`en-GB`, `cs-CZ`). The device's language when unset. */
  locale?: string
  /**
   * iOS 26: `SpeechTranscriber` or `DictationTranscriber`. Before 26 it sets the task hint. Android: formatting tuned
   * for quality or for latency.
   * @default 'transcription'
   */
  mode?: SpeechMode
  /**
   * Where the audio is recognized.
   * - `required`: on the device only. A missing model is installed first; a device or locale that cannot fails.
   * - `preferred`: on the device when the model is there, otherwise on the platform's server for now. iOS 26 installs
   *   the model in the background for next time; Android asks the user before a download, so it leaves that to
   *   `installLocaleAsync`. iOS 26 reaches the server through `SFSpeechRecognizer`, which needs the speech
   *   recognition permission: without it, or offline, it waits for the model as `required` does.
   * - `off`: the platform decides. Android uses its default recognizer, iOS before 26 Apple's servers, iOS 26 the
   *   device anyway.
   * @default 'required'
   */
  onDevice?: OnDevice
  /**
   * Words and phrases the audio is likely to contain: names, jargon ("Verstappen", "box this lap"). iOS honours them
   * in `dictation` mode and before 26; Android biases towards them from Android 13.
   */
  contextualStrings?: string[]
  /**
   * Punctuation and capitalisation. iOS 26's `transcription` mode always punctuates.
   * @default true
   */
  punctuation?: boolean
  /**
   * Report results while the recognizer is still revising them, as the volatile last segment.
   * @default true
   */
  volatileResults?: boolean
  /**
   * Other readings of each segment, in `TranscriptSegment.alternatives`.
   * @default false
   */
  alternatives?: boolean
  /**
   * Replace offensive words. iOS: etiquette replacements. Android: masking, which the platform turns on by default.
   */
  maskOffensiveWords?: boolean
  /**
   * Report when speech starts and stops, as `speech` events. iOS 26 runs `SpeechDetector` at this sensitivity.
   * @default false
   */
  detectSpeech?: boolean | 'low' | 'medium' | 'high'
  /**
   * How many file transcriptions run at once. The rest wait in the transcriber's queue.
   * @default 1
   */
  maxConcurrent?: number
  ios?: SpeechTranscriberIOSOptions
  android?: SpeechTranscriberAndroidOptions
}

export type SpeechTranscriberIOSOptions = {
  /**
   * `auto` takes `analyzer` on iOS 26 and later and `recognizer` before.
   * @default 'auto'
   */
  engine?: 'auto' | 'analyzer' | 'recognizer'
  /**
   * iOS 26 `transcription` mode: favour speed over accuracy for live results (`fastResults`).
   * @default false
   */
  fastResults?: boolean
  /** iOS 26 `dictation` mode: what the audio is like. */
  contentHints?: ('shortForm' | 'farField' | 'atypicalSpeech')[]
  /**
   * iOS 26 `dictation` mode: turn spoken emoji names into emoji.
   * @default false
   */
  emoji?: boolean
  /**
   * iOS 26 `dictation` mode: finalize results more often, so they settle sooner.
   * @default false
   */
  frequentFinalization?: boolean
  /** The recognizer's task hint before iOS 26. Follows `mode` when unset. */
  taskHint?: 'unspecified' | 'dictation' | 'search' | 'confirmation'
  /** A model from `prepareCustomLanguageModelAsync` (iOS 17 and later). iOS 26 uses it in `dictation` mode. */
  customLanguageModel?: CustomLanguageModel
  /**
   * How long iOS 26 keeps the model in memory after the transcriber is done with it.
   * @default 'lingering'
   */
  modelRetention?: 'whileInUse' | 'lingering' | 'processLifetime'
  /**
   * The task priority iOS 26 analyses at.
   * @default 'userInitiated'
   */
  priority?: 'background' | 'utility' | 'low' | 'medium' | 'high' | 'userInitiated'
  /**
   * iOS 27: analyse even when the system is short of resources.
   * @default false
   */
  ignoresResourceLimits?: boolean
}

export type SpeechTranscriberAndroidOptions = {
  /**
   * The recognition service to use, as `package/class`, instead of the system's default (or on-device) one.
   */
  recognitionService?: string
  /**
   * Android 13: how punctuation is added. `quality` waits longer for better punctuation; `latency` keeps live
   * results fast. Follows `mode` when unset.
   */
  formatting?: 'quality' | 'latency'
  /** Android 13: no punctuation after the last word of a volatile result. */
  hidePartialTrailingPunctuation?: boolean
  /** Android 13: let the recognizer bias towards the device's context (contacts, apps). */
  biasingDeviceContext?: boolean
  /**
   * Android 14: detect the spoken language, reported as `language` events and on each segment.
   */
  languageDetection?: boolean | {allowedLanguages?: string[]}
  /**
   * Android 14: switch to the language being spoken. The languages must be installed.
   */
  languageSwitch?: {
    mode?: 'highPrecision' | 'balanced' | 'quickResponse'
    allowedLanguages?: string[]
    /** Android 15. */
    maxSwitches?: number
    /** Android 15: only switch during this many milliseconds after speech starts. */
    initialActiveDurationMillis?: number
  }
  /** Prefer the offline model when the default recognizer is used (`onDevice` `off`, or `preferred` without the model). */
  preferOffline?: boolean
  /** How many readings the recognizer returns per result. Raised to 5 by `alternatives`. */
  maxResults?: number
  /**
   * Extra `RecognizerIntent` extras, by key, for what a recognition service supports beyond the platform's own.
   */
  extras?: Record<string, string | number | boolean | string[]>
  /**
   * How many times faster than real time a file is fed to the recognizer. Fed at full speed, Google's on-device
   * recognizer finalizes late and drops whole sentences; at 4 it keeps every one.
   * @default 4
   */
  feedSpeed?: number
}

export type TranscribeOptions = {
  /**
   * Identifies the audio. A transcription with the same key that is still queued or running is returned instead of a
   * new one, and a finished transcript is kept on disk and returned at once the next time.
   */
  cacheKey?: string
  /**
   * Where the transcription goes in the queue: `high` before everything waiting, `low` after it.
   * @default 'normal'
   */
  priority?: 'high' | 'normal' | 'low'
  /** Transcribe only part of the file, in seconds. Times in the transcript stay relative to the whole file. */
  range?: {start?: number; end?: number}
  /** Headers for downloading a remote source. */
  headers?: Record<string, string>
}

export type ListenOptions = {
  /**
   * Keep the audio as a 16 kHz mono WAV file, in `Transcript.audioUri`, ready for playback with highlighting.
   * @default false
   */
  record?: boolean
  /**
   * Milliseconds between `volume` events. `0` sends none.
   * @default 0
   */
  volumeInterval?: number
  /**
   * Stop by itself, as `stop()` does: `afterSilence` milliseconds after the last thing heard, or `withoutSpeech`
   * milliseconds after the microphone opens when nothing has been said. For a search field or a single answer. Heard
   * means the transcript changed (so it wants `volatileResults`, the default) or, with `detectSpeech`, speech was
   * detected. Off by default: listening runs until `stop()`.
   */
  autoStop?: {afterSilence?: number; withoutSpeech?: number}
  /**
   * Echo cancellation and noise suppression on the microphone, for audio playing while the user speaks. iOS: voice
   * processing. Android 13: the voice communication source with the platform's echo canceler and noise suppressor.
   * @default false
   */
  voiceProcessing?: boolean
  /**
   * Milliseconds the microphone may take to open: loading the engine and its model, the audio session. When it has
   * not opened by then, the transcription fails as `start-timeout`, whose message says what it was waiting for. A model
   * download that keeps moving starts the wait over. `0` waits as long as it takes.
   * @default 10000
   */
  startTimeout?: number
  ios?: {
    /**
     * `auto` sets the audio session to play and record while listening and deactivates it afterwards; `manual`
     * leaves the session to the app.
     * @default 'auto'
     */
    audioSession?: 'auto' | 'manual'
  }
  android?: {
    /** Milliseconds of silence after which the recognizer may stop (Android before 13 only; later it never stops). */
    silenceMillis?: number
  }
}

/** A source: a `file://` or `content://` URI, an `http(s)://` URL (downloaded once, then cached), or a `require()`d asset. */
export type SpeechSource = string | number | {uri: string; headers?: Record<string, string>}

export type TranscriptionState =
  | 'queued'
  | 'downloading'
  /** A file's engine loading, or the microphone opening: listening has not started yet. */
  | 'preparing'
  /** The microphone: open and heard. */
  | 'transcribing'
  /** The microphone, between `pause()` and `resume()`. */
  | 'paused'
  | 'completed'
  | 'cancelled'
  | 'failed'

export type SpeechErrorCode =
  /** The user did not allow speech recognition or the microphone. */
  | 'permission-denied'
  /**
   * The device, the OS version or the engine cannot do what was asked. Also an iOS Simulator that cannot get or run the
   * speech model, which the iOS 26.5 and 27.0 runtimes cannot.
   */
  | 'unsupported'
  /** The locale is not supported, or its model is not installed and could not be. */
  | 'locale-unavailable'
  /** The audio could not be read, decoded or recorded. */
  | 'audio'
  /** A remote source could not be downloaded, or a server recognizer was unreachable. */
  | 'network'
  /** The recognizer is busy with another session. */
  | 'busy'
  /** Another app or a call took the microphone. */
  | 'interrupted'
  /** The recognition service failed. */
  | 'service'
  /** `cancel()`, `stop()` before the microphone opened, or the transcriber was released: what `wait()` rejects with. */
  | 'cancelled'
  /**
   * The microphone did not open within `startTimeout`. The message says what it waited for: the engine or its model
   * loading, a model download that stopped moving, or the microphone itself. Offer to try again, or to type.
   */
  | 'start-timeout'
  | 'unknown'

export type SpeechError = {code: SpeechErrorCode; message: string}

export type TranscriptionEvents = {
  /** New final segments and the current volatile one. */
  update(event: {segments: TranscriptSegment[]; volatile: TranscriptSegment | null}): void
  stateChange(event: {state: TranscriptionState; error: SpeechError | null}): void
  /**
   * From 0 to 1, by phase: the locale's model being installed, a remote file being downloaded, then how much of the
   * audio has been analysed (files only).
   */
  progress(event: {phase: 'installing' | 'downloading' | 'transcribing'; fraction: number}): void
  /** Speech started (`detected: true`) or stopped, at `time` seconds into the audio. Needs `detectSpeech`. */
  speech(event: {detected: boolean; time: number}): void
  /** The microphone's level in dBFS (from -160 to 0), every `volumeInterval` milliseconds. */
  volume(event: {level: number}): void
  /** Android 14: the language detected in the latest audio, and what a language switch did about it. */
  language(event: {
    locale: string
    confidence: 'unknown' | 'low' | 'medium' | 'high'
    switchResult: 'notAttempted' | 'succeeded' | 'failed' | 'skippedNoModel' | null
  }): void
}

/** `unsupported`, `supported` (can be downloaded), `downloading` or `installed`. */
export type LocaleStatus = 'unsupported' | 'supported' | 'downloading' | 'installed'

export type LocaleOptions = {
  /** @default 'transcription' */
  mode?: SpeechMode
  /** Android: ask the on-device recognizer (the default) or the default one, which may be online. */
  onDevice?: boolean
}

export type SpeechAvailability = {
  engine: SpeechEngine
  /** Whether speech recognition can run at all. */
  available: boolean
  /** iOS 26: `SpeechTranscriber` is available on this device. */
  transcriber: boolean
  /** iOS 26: `DictationTranscriber` is available on this device. */
  dictation: boolean
  /** Recognition without a network connection is possible. */
  onDevice: boolean
  /** Files can be transcribed (Android 13 and later). */
  fileTranscription: boolean
  /** Words come with their own times (iOS; Android 14 and later). */
  wordTiming: boolean
  /** Android 14: language detection and switching. */
  languageDetection: boolean
}

export type PermissionStatus = 'granted' | 'denied' | 'undetermined'

export type SpeechPermissionResponse = {
  /** Granted when everything asked for is. */
  status: PermissionStatus
  granted: boolean
  canAskAgain: boolean
  expires: 'never'
  /**
   * iOS: speech recognition, which only `SFSpeechRecognizer` needs. Android has no such permission and reports
   * `granted`.
   */
  speechRecognition: PermissionStatus
  microphone: PermissionStatus
}

/** A custom language model, prepared from phrases and pronunciations (iOS 17 and later). */
export type CustomLanguageModel = {
  languageModel: string
  vocabulary: string | null
  weight?: number
}

export type CustomLanguageModelData = {
  locale: string
  /** Names the model; with `version`, it decides when a prepared model is reused. */
  identifier: string
  version: string
  /** Phrases and how often they occur, relative to each other. */
  phrases?: {phrase: string; count: number}[]
  /** How words are pronounced, in the X-SAMPA phonemes the locale supports. */
  pronunciations?: {grapheme: string; phonemes: string[]}[]
  /** Templates over classes of words: `{templates: [{body: '<driver> box this lap', count: 10}], classes: {driver: ['Lando', 'Oscar']}}`. */
  templates?: {classes: Record<string, string[]>; templates: {body: string; count: number}[]}
  /** How strongly the model counts against the general one, from 0 to 1 (iOS 26). */
  weight?: number
}
