import {AndroidConfig, type ConfigPlugin, type InfoPlist, withAndroidManifest, withInfoPlist} from 'expo/config-plugins'

export type SpeechPluginOptions = {
  /**
   * Why the app asks for speech recognition (iOS, `NSSpeechRecognitionUsageDescription`). Only iOS before 26 asks
   * for it, and only once something is transcribed; `false` leaves the key out, for an app that needs iOS 26.
   */
  speechRecognitionPermission?: string | false
  /**
   * Why the app asks for the microphone: `NSMicrophoneUsageDescription` on iOS, and `RECORD_AUDIO` on Android.
   * `false` leaves both out, for an app that only transcribes files.
   */
  microphonePermission?: string | false
}

export const DEFAULT_SPEECH_RECOGNITION_PERMISSION = 'Allow $(PRODUCT_NAME) to turn speech into text.'
export const DEFAULT_MICROPHONE_PERMISSION = 'Allow $(PRODUCT_NAME) to hear you, to turn your speech into text.'

/** Sets the usage descriptions, keeping any the app has set itself. */
export const addIosPermissions = (infoPlist: InfoPlist, options: SpeechPluginOptions): InfoPlist => {
  const result = {...infoPlist}
  const speech = options.speechRecognitionPermission ?? DEFAULT_SPEECH_RECOGNITION_PERMISSION
  const microphone = options.microphonePermission ?? DEFAULT_MICROPHONE_PERMISSION

  if (speech !== false) {
    result.NSSpeechRecognitionUsageDescription = options.speechRecognitionPermission
      ? speech
      : (infoPlist.NSSpeechRecognitionUsageDescription ?? speech)
  }
  if (microphone !== false) {
    result.NSMicrophoneUsageDescription = options.microphonePermission
      ? microphone
      : (infoPlist.NSMicrophoneUsageDescription ?? microphone)
  }
  return result
}

export const RECORD_AUDIO = 'android.permission.RECORD_AUDIO'

/** The microphone permission, unless the app transcribes files only. */
export const addAndroidPermissions = (
  manifest: AndroidConfig.Manifest.AndroidManifest,
  options: SpeechPluginOptions
): AndroidConfig.Manifest.AndroidManifest => {
  if (options.microphonePermission !== false) {
    AndroidConfig.Permissions.ensurePermission(manifest, RECORD_AUDIO)
  }
  return manifest
}

/**
 * The permissions speech to text needs. Android's `<queries>` for the recognition service ships in the library's own
 * manifest and merges by itself.
 */
export const withSpeech: ConfigPlugin<SpeechPluginOptions | void> = (config, options) => {
  const resolved = options ?? {}

  config = withInfoPlist(config, plist => {
    plist.modResults = addIosPermissions(plist.modResults, resolved)
    return plist
  })

  return withAndroidManifest(config, manifest => {
    manifest.modResults = addAndroidPermissions(manifest.modResults, resolved)
    return manifest
  })
}
