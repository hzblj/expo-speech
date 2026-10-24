# @hzblj/expo-speech

[![npm](https://img.shields.io/npm/v/@hzblj/expo-speech.svg)](https://www.npmjs.com/package/@hzblj/expo-speech)
[![license](https://img.shields.io/npm/l/@hzblj/expo-speech.svg)](https://github.com/hzblj/expo-speech/blob/main/LICENSE)

Speech to text for Expo on the platforms' own Speech APIs, on the device. Files and the microphone, a time for every word, and highlighting while the audio plays.

- **iOS 26:** `SpeechAnalyzer` with `SpeechTranscriber` (or `DictationTranscriber`), its models installed on demand through `AssetInventory`. Before iOS 26: `SFSpeechRecognizer`.
- **Android:** the on-device `SpeechRecognizer` (Android 12), files and the microphone streamed to it in a segmented session (Android 13), words timed by `RecognitionPart` (Android 14), language models installed on demand.
- **Every word timed,** with its place in the text: `transcript.text.slice(...word.range) === word.text`.
- **A queue with a cache:** transcriptions run a few at a time, highest priority first; the same audio asked for twice is transcribed once, and a finished transcript comes back at once from disk.
- **Karaoke playback:** `useTranscriptPlayback` follows an expo-audio or expo-video player word by word, on time, without polling it; `TranscriptText` lights the words.
- **Subtitles:** `toWebVTT` and `toSRT`.

This is not text to speech: for speaking, use Expo's own `expo-speech`.

## Install

```sh
npx expo install @hzblj/expo-speech
```

Requires Expo SDK 57 or newer and a [development build](https://docs.expo.dev/develop/development-builds/introduction/). Expo Go doesn't include this native module.

Add the config plugin. It sets the iOS usage descriptions and Android's microphone permission:

```json
{
  "plugins": [["@hzblj/expo-speech", {"microphonePermission": "Allow $(PRODUCT_NAME) to hear you."}]]
}
```

| Option | Default | Meaning |
| --- | --- | --- |
| `microphonePermission` | A generic text | `NSMicrophoneUsageDescription` on iOS and `RECORD_AUDIO` on Android. `false` leaves both out, for an app that only transcribes files. |
| `speechRecognitionPermission` | A generic text | `NSSpeechRecognitionUsageDescription`. Only `SFSpeechRecognizer` (before iOS 26) asks for it. `false` leaves it out. |

## Transcribe a file

```tsx
import {SpeechTranscriber} from '@hzblj/expo-speech'

const transcriber = new SpeechTranscriber({locale: 'en-GB'})
const transcript = await transcriber.transcribe('https://example.com/radio.mp3').wait()

transcript.text // "Box, box. Box this lap."
transcript.words // [{text: 'Box,', start: 0.06, end: 0.72, range: [0, 4], confidence: 0.85, timing: 'measured'}, ...]
```

A source is a `file://` or `content://` URI, an `http(s)://` URL (downloaded once, then kept), or a `require()`d asset. Any audio the platform decodes works: mp3, m4a, aac, wav, ogg, and the audio of an mp4.

In a component, `useTranscribe` does the same and follows it as it runs:

```tsx
import {useSpeechTranscriber, useTranscribe} from '@hzblj/expo-speech'

const RadioMessage = ({url}: {url: string}) => {
  const transcriber = useSpeechTranscriber({contextualStrings: ['Verstappen', 'box box'], locale: 'en-GB'})
  const {progress, state, transcript} = useTranscribe(transcriber, url, {cacheKey: url})

  return <Text>{state === 'completed' ? transcript.text : `${Math.round(progress * 100)} %`}</Text>
}
```

Keep one transcriber per configuration and share it: it holds the queue, and on iOS the model stays loaded between transcriptions.

## Highlight the words while they play

```tsx
import {TranscriptText, useTranscriptPlayback} from '@hzblj/expo-speech'
import {useAudioPlayer} from 'expo-audio'

const Karaoke = ({transcript}: {transcript: Transcript}) => {
  const player = useAudioPlayer(transcript.audioUri)
  const {wordIndex} = useTranscriptPlayback(transcript, player)

  return (
    <TranscriptText
      activeWordStyle={{color: '#e10600'}}
      onWordPress={word => player.seekTo(word.start)}
      spokenWordStyle={{color: 'white'}}
      transcript={transcript}
      upcomingWordStyle={{color: 'gray'}}
      wordIndex={wordIndex}
    />
  )
}
```

`transcript.audioUri` is the local copy of what was transcribed, so a downloaded file plays offline. Players report their time a few times a second; the hook reckons the time in between and wakes exactly when the next word starts, so it re-renders once per word. It works with anything that has `currentTime`, `playing` and the events expo-audio's `AudioPlayer` or expo-video's `VideoPlayer` send. For a timeline of your own, `wordIndexAt(transcript, seconds)` finds the word at a time.

## The microphone

```tsx
import {Speech, useTranscription} from '@hzblj/expo-speech'

const permission = await Speech.requestPermissionsAsync()
const transcription = transcriber.listen({record: true, volumeInterval: 60})

// later
transcription.stop() // finalizes what was heard; `cancel()` drops it
```

`useTranscription(transcription)` gives the transcript as it is heard (the last segment volatile until the recognizer settles it), the microphone's `level` in dBFS and, with `detectSpeech`, whether someone is `speaking`. With `record`, the audio is kept as a 16 kHz mono WAV file in `transcript.audioUri`, ready to play back with its words lit. One `listen` runs at a time in the app.

On iOS the audio session is set to play and record while listening and let go of afterwards (`ios.audioSession: 'manual'` leaves it to you). A call that takes the microphone ends the transcription as if stopped: what was heard is final, and `error.code` is `interrupted`. A change of route (AirPods in or out) is followed without a gap.

## Transcriptions

`transcribe` returns a `Transcription` at once, a native object shared with JavaScript:

| Member | Meaning |
| --- | --- |
| `state` | `queued`, `downloading`, `preparing`, `transcribing`, then `completed`, `cancelled` or `failed` |
| `transcript` | What has been recognized so far |
| `progress` | From 0 to 1, for files |
| `fromCache` | Answered from the cache, without transcribing |
| `error` | `{code, message}` once it failed (or ended early) |
| `wait()` | Resolves with the final transcript; rejects when it fails or is cancelled |
| `stop()`, `cancel()` | Stop and finalize (the microphone), or drop it |

Its events: `update` (new final segments and the current volatile one), `stateChange`, `progress` (`installing` a model, `downloading` a file, then `transcribing`), `speech`, `volume` and, on Android 14, `language`.

`transcribe(source, options)` takes:

| Option | Meaning |
| --- | --- |
| `cacheKey` | Identifies the audio: a transcription of it already queued or running is returned instead of a new one, and a finished transcript is kept on disk and returned at once next time |
| `priority` | `high`, `normal` or `low`: where it goes in the queue |
| `range` | `{start, end}` in seconds: only part of the file, with times kept in the whole file's seconds |
| `headers` | For downloading a remote source |

## Options

Shared options apply to both platforms; what only one platform can do is under `ios` or `android` and is ignored on the other.

| Option | Default | Meaning |
| --- | --- | --- |
| `locale` | The device's | A BCP 47 tag, `en-GB`, `cs-CZ` |
| `mode` | `transcription` | `transcription` for recordings and long audio, `dictation` for speech meant as text (iOS 26: `DictationTranscriber`) |
| `onDevice` | `true` | Keep the audio on the device. iOS 26 always does. Off, Android may use its default recognizer's service and iOS before 26 Apple's servers |
| `contextualStrings` | None | Names and jargon the audio is likely to contain. Honoured by dictation on iOS 26, by `SFSpeechRecognizer`, and by Android 13's biasing |
| `punctuation` | `true` | Punctuation and capitals |
| `volatileResults` | `true` | Results while the recognizer still revises them |
| `alternatives` | `false` | Other readings of each segment |
| `maskOffensiveWords` | Platform's | iOS etiquette replacements, Android masking |
| `detectSpeech` | `false` | `speech` events; iOS 26 runs `SpeechDetector` at this sensitivity (`low`, `medium`, `high`) |
| `maxConcurrent` | `1` | File transcriptions at once |

| `ios` | Default | Meaning |
| --- | --- | --- |
| `engine` | `auto` | `analyzer` (iOS 26) or `recognizer` (`SFSpeechRecognizer`) |
| `fastResults` | `false` | Faster volatile results in transcription mode |
| `contentHints` | None | Dictation: `shortForm`, `farField`, `atypicalSpeech` |
| `emoji`, `frequentFinalization` | `false` | Dictation options |
| `taskHint` | From `mode` | `SFSpeechRecognizer`'s task hint |
| `customLanguageModel` | None | From `Speech.prepareCustomLanguageModelAsync` |
| `modelRetention` | `lingering` | How long iOS 26 keeps the model loaded |
| `priority` | `userInitiated` | The analysis task's priority |
| `ignoresResourceLimits` | `false` | iOS 27 |

| `android` | Default | Meaning |
| --- | --- | --- |
| `recognitionService` | The on-device one | A `package/class` to use instead |
| `formatting` | From `mode` | `quality` or `latency` (Android 13) |
| `languageDetection` | `false` | `true` or `{allowedLanguages}` (Android 14) |
| `languageSwitch` | None | `{mode, allowedLanguages, maxSwitches, initialActiveDurationMillis}` (Android 14 and 15) |
| `hidePartialTrailingPunctuation`, `biasingDeviceContext`, `preferOffline`, `maxResults` | Platform's | The `RecognizerIntent` extras of the same names |
| `extras` | None | Any other `RecognizerIntent` extras, by key |
| `feedSpeed` | `4` | How many times faster than real time a file goes to the recognizer |

## Languages and models

```tsx
const availability = await Speech.getAvailabilityAsync() // engine, onDevice, fileTranscription, wordTiming, ...
const locales = await Speech.getSupportedLocalesAsync()
const status = await Speech.getLocaleStatusAsync('cs-CZ') // unsupported, supported, downloading or installed
await Speech.installLocaleAsync('cs-CZ', {onProgress: fraction => console.log(fraction)})
```

A transcription installs its locale's model by itself when it is missing; `installLocaleAsync` does it ahead of time. On Android the system asks the user before downloading. iOS 26 keeps the assets of up to `Speech.maximumReservedLocales` locales per app (`reserveLocaleAsync`, `releaseLocaleAsync`), and `endModelRetentionAsync` unloads a lingering model.

`Speech.prepareCustomLanguageModelAsync({locale, identifier, version, phrases, pronunciations, templates})` builds an iOS 17 custom language model, for `ios.customLanguageModel`. Android has none and resolves `null`.

`Speech.clearCacheAsync()` deletes cached transcripts and downloaded audio.

## Errors

Errors carry a `code`: `permission-denied`, `unsupported`, `locale-unavailable`, `audio`, `network`, `busy`, `interrupted`, `service`, `cancelled` or `unknown`. Audio without speech is not an error: it completes with an empty transcript. A transcription shared through a `cacheKey` is taken off the queue by `useTranscribe` only when the last component following it unmounts.

## Platform behavior

| | iOS 26 | iOS 16.4 to 25 | Android 14 | Android 13 | Android 12 |
| --- | --- | --- | --- | --- | --- |
| Engine | SpeechAnalyzer | SFSpeechRecognizer | SpeechRecognizer | SpeechRecognizer | SpeechRecognizer |
| Files | Yes | Yes | Yes | Yes | No |
| Word times | Measured | Measured | Measured starts | Estimated | Estimated |
| Permission for files | None | Speech recognition | None | None | None |
| Models on demand | Yes | No | Yes, with progress | Yes | No |

- **Word times.** A word the platform did not time (Android 13, a phrase timed as one, a result still being revised) gets its share of the stretch around it by its length, and says so in `timing: 'estimated'`. Android times only where a word starts; it ends where the next one starts, or after a time for its length.
- **Android runs one session at a time,** as its recognition services do. The microphone goes first: it skips the files waiting, and a file being transcribed makes way and continues afterwards from the end of its final text. Downloads and decoding go ahead meanwhile.
- **The iOS simulator** has no `SpeechTranscriber`: it falls back to `DictationTranscriber`. The simulator's microphone needs the Simulator app to have microphone access on the Mac.

## Example

`apps/example` in the [repository](https://github.com/hzblj/expo-speech) transcribes a Formula 1 weekend's team radio (captured from [OpenF1](https://openf1.org)) on the device, and plays it back with its words lit.

## License

MIT © Jan Blazej
