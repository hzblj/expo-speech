import {ExpoSpeech} from './ExpoSpeechModule'
import type {
  CustomLanguageModel,
  CustomLanguageModelData,
  LocaleOptions,
  LocaleStatus,
  SpeechAvailability,
  SpeechPermissionResponse,
} from './types'

export type PermissionOptions = {
  /** @default true */
  microphone?: boolean
  /** iOS: speech recognition. By default only where `SFSpeechRecognizer` runs: before iOS 26. */
  speechRecognition?: boolean
}

const localeOptions = ({mode = 'transcription', onDevice = true}: LocaleOptions = {}) => ({mode, onDevice})

/**
 * What the device can do, the languages it can do it in, and the permissions it takes. Transcribing itself goes
 * through a `SpeechTranscriber`.
 */
export const Speech = {
  /** Deletes cached transcripts and downloaded audio. */
  clearCacheAsync: ({audio = true, transcripts = true}: {transcripts?: boolean; audio?: boolean} = {}) =>
    ExpoSpeech.clearCacheAsync({audio, transcripts}),

  /** iOS 26: unloads models kept by `modelRetention`, now rather than when the system decides. */
  endModelRetentionAsync: (): Promise<void> => ExpoSpeech.endModelRetentionAsync(),

  /** Which engine runs and what it can do here. */
  getAvailabilityAsync: (options?: LocaleOptions): Promise<SpeechAvailability> =>
    ExpoSpeech.getAvailabilityAsync(localeOptions(options)),

  /** The locales whose models are on the device now. */
  getInstalledLocalesAsync: (options?: LocaleOptions): Promise<string[]> =>
    ExpoSpeech.getInstalledLocalesAsync(localeOptions(options)),

  getLocaleStatusAsync: (locale: string, options?: LocaleOptions): Promise<LocaleStatus> =>
    ExpoSpeech.getLocaleStatusAsync(locale, localeOptions(options)),

  /**
   * The permissions transcribing takes: the microphone (for `listen`), and on iOS speech recognition, which only
   * `SFSpeechRecognizer` needs (before iOS 26, or with `ios.engine: 'recognizer'`). By default speech recognition is
   * asked about only where that engine runs; files need no permission at all on iOS 26 and Android.
   */
  getPermissionsAsync: (options: PermissionOptions = {}): Promise<SpeechPermissionResponse> =>
    ExpoSpeech.getPermissionsAsync(options.microphone ?? true, options.speechRecognition ?? null),

  /**
   * iOS 26: the locales the app keeps assets for. The system keeps up to `maximumReservedLocales` per app and reserves
   * a locale by itself when a transcriber uses it. Android: always empty.
   */
  getReservedLocalesAsync: (): Promise<string[]> => ExpoSpeech.getReservedLocalesAsync(),

  /** Every locale the engine can transcribe, installed or not, as BCP 47 tags. */
  getSupportedLocalesAsync: (options?: LocaleOptions): Promise<string[]> =>
    ExpoSpeech.getSupportedLocalesAsync(localeOptions(options)),

  /**
   * Downloads the locale's model. iOS 26: through `AssetInventory`, with progress. Android 13: the recognizer's model
   * download, which the system asks the user about, with progress from Android 14; on Android 13 it resolves once
   * the download is scheduled.
   */
  installLocaleAsync: async (
    locale: string,
    {onProgress, ...options}: LocaleOptions & {onProgress?: (fraction: number) => void} = {}
  ): Promise<void> => {
    const resolved = localeOptions(options)
    const subscription = onProgress
      ? ExpoSpeech.addListener('installProgress', event => {
          if (event.locale === locale && event.mode === resolved.mode) {
            onProgress(event.fraction)
          }
        })
      : null

    try {
      await ExpoSpeech.installLocaleAsync(locale, resolved)
    } finally {
      subscription?.remove()
    }
  },

  get maximumReservedLocales(): number {
    return ExpoSpeech.maximumReservedLocales
  },

  /**
   * iOS 17: builds a custom language model from phrases, templates and pronunciations, for a transcriber's
   * `ios.customLanguageModel`. Prepared once per identifier and version. Android has none and resolves `null`.
   */
  prepareCustomLanguageModelAsync: (data: CustomLanguageModelData): Promise<CustomLanguageModel | null> =>
    ExpoSpeech.prepareCustomLanguageModelAsync(data),

  /** Frees a reserved locale, so its assets may go when the system needs the space. */
  releaseLocaleAsync: (locale: string): Promise<boolean> => ExpoSpeech.releaseLocaleAsync(locale),

  /** Asks for what `getPermissionsAsync` reports, where it has not been answered yet. */
  requestPermissionsAsync: (options: PermissionOptions = {}): Promise<SpeechPermissionResponse> =>
    ExpoSpeech.requestPermissionsAsync(options.microphone ?? true, options.speechRecognition ?? null),

  reserveLocaleAsync: (locale: string): Promise<boolean> => ExpoSpeech.reserveLocaleAsync(locale),
}
