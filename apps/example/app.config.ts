import type {ExpoConfig} from 'expo/config'

// Not "Expo Speech": the generated Xcode target would be `ExpoSpeech`, the Swift module of the package's native module.
const NAME = 'Speech Example'
const BUNDLE_ID = 'com.hzblj.expospeech.example'

export default {
  android: {
    package: BUNDLE_ID,
  },
  experiments: {
    typedRoutes: true,
  },
  ios: {
    bundleIdentifier: BUNDLE_ID,
    supportsTablet: true,
  },
  name: NAME,
  orientation: 'portrait',
  plugins: [
    'expo-router',
    // The example's icons (Material Symbols): every SVG in assets/icons becomes a native asset on both platforms, and
    // its name a type in native-icons.d.ts.
    ['@hzblj/kara-ui', {icons: {source: './assets/icons'}}],
    // Plays the team radio back. Its own microphone text would win over expo-speech's, so it gets the same one.
    [
      'expo-audio',
      {
        enableBackgroundPlayback: false,
        microphonePermission: 'Allow $(PRODUCT_NAME) to hear you, to turn your speech into text.',
      },
    ],
    // The usage descriptions and the microphone permission. Built from packages/expo-speech, which is why
    // `yarn prebuild` builds it first.
    '@hzblj/expo-speech',
  ],
  scheme: 'speech-example',
  slug: 'expo-speech-example',
  userInterfaceStyle: 'dark',
  version: '1.0.0',
} satisfies ExpoConfig
