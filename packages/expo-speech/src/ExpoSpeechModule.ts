import {type NativeModule, requireNativeModule, type SharedObject} from 'expo'

import type {
  CustomLanguageModel,
  CustomLanguageModelData,
  ListenOptions,
  LocaleOptions,
  LocaleStatus,
  SpeechAvailability,
  SpeechEngine,
  SpeechError,
  SpeechPermissionResponse,
  SpeechSource,
  SpeechTranscriberOptions,
  TranscribeOptions,
  Transcript,
  TranscriptionEvents,
  TranscriptionState,
} from './types'

/**
 * One transcription: a file in the transcriber's queue, or the microphone while `listen` runs. A native object shared
 * with JavaScript, released when nothing references it.
 */
export declare class Transcription extends SharedObject<TranscriptionEvents> {
  /** Unique for the app's lifetime. */
  readonly id: string
  readonly kind: 'file' | 'microphone'
  readonly state: TranscriptionState
  /** The `cacheKey` it was started with. */
  readonly cacheKey: string | null
  /** Whether the transcript came from the cache, without transcribing anything. */
  readonly fromCache: boolean
  /** From 0 to 1, for files whose length is known. */
  readonly progress: number
  /** What has been recognized so far. A new object on every read: read it once per render. */
  readonly transcript: Transcript
  readonly error: SpeechError | null
  /** Resolves with the final transcript; rejects when the transcription fails or is cancelled. */
  wait(): Promise<Transcript>
  /** Stop listening and finalize what was heard. For a file, the same as `cancel`. */
  stop(): void
  /** Drop it: out of the queue, or stopped where it is without finalizing. */
  cancel(): void
}

/**
 * A recognizer for one locale and configuration. Files go through its queue; the microphone through `listen`. Keep one
 * per configuration (the `useSpeechTranscriber` hook does) so the model stays warm.
 */
export declare class SpeechTranscriber extends SharedObject<Record<never, never>> {
  constructor(options?: SpeechTranscriberOptions)
  /** The locale actually used, as a BCP 47 tag: the requested one or its supported equivalent. */
  readonly locale: string
  readonly engine: SpeechEngine
  /** Transcriptions waiting in the queue or running. */
  readonly pending: number
  /**
   * Gets the model ready ahead of the first transcription: on iOS 26 it downloads the locale's assets (with
   * `download`) and loads the analyzer; on Android it creates the recognizer and checks the locale.
   */
  prepareAsync(options?: {download?: boolean}): Promise<void>
  /**
   * Queue a file. Returns the transcription at once; `wait()` for the transcript or follow it with
   * `useTranscription`. With a `cacheKey`, a transcription of the same audio is reused.
   */
  transcribe(source: SpeechSource, options?: TranscribeOptions): Transcription
  /** @hidden The native side of `transcribe`, after the source is resolved. */
  transcribeUri(uri: string, options: TranscribeOptions): Transcription
  /** Start transcribing the microphone. One at a time per app. */
  listen(options?: ListenOptions): Transcription
  /** Cancel everything queued and running. */
  cancelAll(): void
}

type ExpoSpeechEvents = {
  installProgress(event: {locale: string; mode: string; fraction: number}): void
}

declare class ExpoSpeechNativeModule extends NativeModule<ExpoSpeechEvents> {
  SpeechTranscriber: typeof SpeechTranscriber
  Transcription: typeof Transcription
  getPermissionsAsync(microphone: boolean, speechRecognition: boolean | null): Promise<SpeechPermissionResponse>
  requestPermissionsAsync(microphone: boolean, speechRecognition: boolean | null): Promise<SpeechPermissionResponse>
  getAvailabilityAsync(options: LocaleOptions): Promise<SpeechAvailability>
  getSupportedLocalesAsync(options: LocaleOptions): Promise<string[]>
  getInstalledLocalesAsync(options: LocaleOptions): Promise<string[]>
  getLocaleStatusAsync(locale: string, options: LocaleOptions): Promise<LocaleStatus>
  installLocaleAsync(locale: string, options: LocaleOptions): Promise<void>
  getReservedLocalesAsync(): Promise<string[]>
  reserveLocaleAsync(locale: string): Promise<boolean>
  releaseLocaleAsync(locale: string): Promise<boolean>
  readonly maximumReservedLocales: number
  endModelRetentionAsync(): Promise<void>
  prepareCustomLanguageModelAsync(data: CustomLanguageModelData): Promise<CustomLanguageModel | null>
  clearCacheAsync(options: {transcripts: boolean; audio: boolean}): Promise<void>
}

export const ExpoSpeech = requireNativeModule<ExpoSpeechNativeModule>('ExpoSpeech')
