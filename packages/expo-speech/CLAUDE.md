# @hzblj/expo-speech

Speech to text for Expo on the platforms' own Speech APIs. An Expo module (`ExpoSpeech`: `ios/`, `android/`), its JS
(`src/` → `build/`) and a config plugin (`plugin/` → `plugin/build/`, loaded through `app.plugin.js`).

## The shape

**Two shared objects.** `SpeechTranscriber` is a configuration (locale, mode, options) with a queue of file
transcriptions; `Transcription` is one of them, or the microphone. Both are native `SharedObject`s, released when
JavaScript lets go (`useSpeechTranscriber` releases on unmount and cancels what is still queued). Options arrive as
plain objects and are decoded natively (`ios/Core/Options.swift`, `android/.../Options.kt`), which is where the
documented defaults live: keep them in step with the JSDoc in `src/types.ts`.

**`transcribe` is JavaScript.** `src/transcriber.ts` puts it on the native class's prototype: a `require()`d asset
becomes a URI there (only React Native can resolve one), then `transcribeUri` goes native.

**One transcript model, built natively, mirrored in JS.** Engines report `RecognizedResult`s (text runs, timed or not);
`TranscriptAssembler` (Swift and Kotlin, the same rules, the same tests) turns them into segments and words with UTF-16
offsets into the transcript's text, splits multi-word runs, estimates untimed words by length, glues punctuation that
touches a word onto it, and puts a space between segments that come without one (Android's). Events carry new final
segments and the current volatile one; `applyTranscriptUpdate` (`src/transcript.ts`) rebuilds the same transcript in
JS and returns `null` on a gap, so `useTranscription` reads `transcription.transcript` again.

**Queue, dedupe, cache.** Per transcriber: up to `maxConcurrent` at once, `priority` high first then arrival order; a
`cacheKey` returns the transcription already queued or running for it, and a finished transcript is kept as JSON under
Caches (`expo-speech/transcripts`, keyed by key, locale, engine and the options that change the text) and answered from
there at once, without queueing. Remote audio is downloaded once per URL (`expo-speech/audio`), shared between
concurrent requests.

**`TranscriptText` groups words into spans.** Consecutive words with the same state share one styled span; with
`onWordPress` each word is an unstyled span inside them, only to be pressed. Android styles at most 255 span
operations per text ("Text tree size exceeded the limit"), which a span per styled word passes at about 30 words.

**Permissions.** Speech recognition authorization is `SFSpeechRecognizer`'s alone (SpeechAnalyzer transcribes without
it, measured on macOS 26), so `requestPermissionsAsync` asks for it only where that engine runs unless told to; its
system prompt says the audio goes to Apple, which on iOS 26 it doesn't.

**The microphone.** `autoStop` is `AutoStop` (Swift and Kotlin, the same rules, the same tests): it fires once, after
silence following the last change of the text (letters and digits only, so a result that only gains punctuation as it
settles is not speech) or of `speech` events, or after a wait with nothing heard; never while speech is detected or
while paused. Its wait for speech starts when the microphone opens (`onStart` / `onStarted`), not at `listen`, so a
model download does not count. `pause()` mutes rather than stops: `MicrophoneCapture` sends zeros, so the recognizer,
the recording and the times go on without a gap, and no session has to end and start again.

**`onDevice` is resolved per run.** `required` installs a missing model first, `off` lets the platform decide.
`preferred`: iOS 26 is `PreferredEngine`, the analyzer once `AssetInventory` says installed, until then
`RecognizerEngine` (Apple's servers) while the model installs in the background; only when the recognizer is usable
(authorized, available), otherwise it waits for the model like `required`. A locale the analyzer has no model for at
all always goes to the recognizer. Android takes the on-device recognizer when its model is installed and the default
one otherwise, and never starts a download itself: `triggerModelDownload` shows the user a dialog.

**Playback is JavaScript only.** `PlaybackFollower` (`src/playback.ts`) dead-reckons the player's time from its last
report and wakes exactly at the next word: no polling, no dependency on expo-audio (anything with `currentTime`,
`playing` and the events expo-audio or expo-video send works).

## iOS (`ios/`)

`Core/` is plain Swift over Foundation and Speech, compiled by the pod and by the SwiftPM package in `Tests/`
(`yarn test:ios`, on the Mac: macOS 26 has the same Speech framework, so the engine tests transcribe real speech that
`say` generates). The module layer (`*.swift` at the top) is the only code that imports ExpoModulesCore.

- **`AnalyzerEngine`** (iOS 26): `SpeechAnalyzer` with `SpeechTranscriber`, or `DictationTranscriber` in dictation mode
  and wherever `SpeechTranscriber.isAvailable` is false (the iOS 26.0 simulator). Assets are installed on demand through
  `AssetInventory` (the `installing` progress phase). Final results keep Apple's per-run `audioTimeRange`; volatile
  results span the whole revised stretch, so their words are estimated.
  In the iOS Simulator a model it cannot get or run (`AssetInventory` never installs it on iOS 27.0, no audio format on
  26.5) fails as `unsupported` with that said (`onSimulator`); on a device the same failures keep their own codes.
  Contextual strings help dictation only (SpeechTranscriber ignores them; measured).
- **`RecognizerEngine`**: `SFSpeechRecognizer` before iOS 26 or with `ios.engine: 'recognizer'`. Needs speech
  authorization; `onDevice` fails for a locale without an on-device model instead of using Apple's servers.
- **`AudioFileReader`** decodes any file AVFoundation reads into the engine's format with `AVAssetReader` (resampling
  included), on demand, with the range applied and times kept in the file's seconds.
- **`MicrophoneCapture`** is `AVAudioEngine` with a converter, rebuilt on a route change (a fixed converter crashes), and
  ended as if stopped when a call interrupts (the transcript is finalized; the error says `interrupted`).
- **Locks.** `NSLock` is not reentrant: read a locked property (`locale`, `state`) before taking the same lock. A nested
  lock on the JS thread froze the app once.
- **The simulator's microphone** goes through the Mac's CoreAudio: without microphone access for the Simulator app,
  `AVAudioEngine.inputNode` hangs and CoreAudio aborts the app ("Cleanup: RPC timeout. Apparently deadlocked"). Not
  ours to fix; test `listen` on a device or after allowing the Simulator the microphone. (The Android emulator's
  microphone works: it records silence.)
- **`MicrophoneCapture` takes `stop` at any time**: before `start` (the stream comes back finished and the microphone
  never opens), during it (honoured once the engine runs), after. Every run stops it when it ends, however it ends,
  and its stream's `onTermination` does too: an engine that fails must not leave the microphone on.
- **`TaskState`** (the recognizer's continuation) keeps an outcome that comes before the continuation: a cancel at the
  wrong moment otherwise leaves a transcription unsettled forever.

## Android (`android/`)

- **`AndroidEngine`**: `SpeechRecognizer`, on-device (`createOnDeviceSpeechRecognizer`, Android 12) unless `onDevice`
  is off or `android.recognitionService` names one. Files and the microphone both go through `EXTRA_AUDIO_SOURCE`
  (Android 13): PCM in a pipe, in a segmented session that ends when the pipe closes, so long audio is never cut at the
  first pause. Word times come from `RECOGNITION_PARTS` (Android 14): a part gives only its start, so it ends at the next
  part's start or after a time for its length, whichever is first. Every `SpeechRecognizer` call is on the main thread.
- **What Google's on-device recognizer (`com.google.android.as`, "Soda") needs, all measured on an Android 17
  emulator:**
  - *Paced files.* Fed at full speed it finalizes segments in a burst at the end and drops whole sentences; at
    `android.feedSpeed` (4× real time) every one comes through (a 17.6 s clip in about 6 s).
  - *Audio before the session.* An empty pipe at the start reads as the end of the audio ("no speech" within 40 ms),
    so the audio starts first and the recognizer once the first chunk is in the pipe; nothing in 8 s is an `audio`
    error. A writer that fails fails the session with its own error, never the "no speech" the closed pipe causes;
    only a failed write into the pipe (`PipeClosed`) means the recognizer let go.
  - *One session at a time* (`getMaxConcurrentSessionsCount`): a second gets ERROR_RECOGNIZER_BUSY. `SessionGate`
    hands out one turn at a time, the microphone first: it goes before waiting files, and a running file session is
    asked to make way (`Preempted`), destroys its recognizer, drops its volatile text and continues later from
    `finalizedThrough`, so nothing is heard twice. Before the gate, a held talk button waited behind the radio's
    queue and recorded nothing. Downloads and decoding still run in parallel.
  - *Don't bind and drop the service right before a session*: `checkRecognitionSupport`'s recognizer, destroyed, can
    take the service down under the next one (ERROR_SERVER_DISCONNECTED before `onReadyForSpeech`). Locale checks are
    cached per process, the engine waits 300 ms after one, and such a session is retried (twice) with fresh audio.
  - *Models*: a missing locale is installed before the first session (`triggerModelDownload`, which shows the system's
    own "Download English (UK) update" dialog); its progress is the `installing` phase.
  - Confidence: the on-device recognizer reports 0 for everything, read as unknown.
- **`AudioDecoder`**: `MediaExtractor` and `MediaCodec` to PCM, then `Resampler` (mixdown, windowed-sinc low-pass,
  linear interpolation) to 16 kHz mono. One decoder per feed, so a retried session starts the file over.
- **`MicrophoneCapture`**: `AudioRecord` (VOICE_RECOGNITION) into the same pipe, a WAV writer and a meter. With
  `voiceProcessing`, VOICE_COMMUNICATION with `AcousticEchoCanceler` and `NoiseSuppressor` on its session, where the
  device has them. Before Android 13 the recognizer's own microphone runs instead, restarted after each utterance
  until `stop`; `RecognizerMicrophone.Control` pauses it between utterances.
- The library manifest's `<queries>` for `android.speech.RecognitionService` is what lets Android 11+ find the service.
- JVM tests: `yarn test:android` (needs the example's prebuilt `android/`).
- Known: a recognizer that reports "no speech" in the middle of a file ends that session as completed (the rest of the
  file is not heard). Not seen with Google's on-device recognizer, which keeps a segmented session through silence.

## Rules

- Shared props at the top, platform-only ones under `ios` / `android`, ignored on the other platform.
- Docs copy (README, the JSDoc in `src/types.ts`, changesets) has no em dashes.
- `yarn lint`, `yarn test`, `yarn test:ios`, `yarn test:android`, `yarn pack:check` before a release.
