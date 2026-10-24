import {ExpoSpeech} from './ExpoSpeechModule'
import type {
  CustomLanguageModel,
  CustomLanguageModelData,
  LocaleOptions,
  LocaleStatus,
  SpeechAvailability,
  SpeechPermissionResponse,
} from './types'

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
   * Speech recognition (iOS) and, with `microphone`, the microphone. Transcribing files needs no permission on iOS 26
   * and Android; iOS before 26 asks for speech recognition.
   */
  getPermissionsAsync: ({microphone = true}: {microphone?: boolean} = {}): Promise<SpeechPermissionResponse> =>
    ExpoSpeech.getPermissionsAsync(microphone),

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
   * download, with progress from Android 14; on Android 13 it resolves once the download is scheduled.
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

  requestPermissionsAsync: ({microphone = true}: {microphone?: boolean} = {}): Promise<SpeechPermissionResponse> =>
    ExpoSpeech.requestPermissionsAsync(microphone),

  reserveLocaleAsync: (locale: string): Promise<boolean> => ExpoSpeech.reserveLocaleAsync(locale),
}
