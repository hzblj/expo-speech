# @hzblj/expo-speech

## 0.3.0

### Minor Changes

- [`4c16259`](https://github.com/hzblj/expo-speech/commit/4c162597547d2a694be1a637bf49b29fe9167383) Thanks [@hzblj](https://github.com/hzblj)! - Native code can follow a transcription's microphone without JavaScript: the root mean square of every 80 ms of audio, as the `expo.audioLevel` notification on iOS (the transcription is the object) and through `addAudioLevelListener` on Android. `@hzblj/expo-waveform`'s `LiveWaveformView` draws it live as its `meter`.

## 0.2.0

### Minor Changes

- [`a54e95c`](https://github.com/hzblj/expo-speech/commit/a54e95cd60e73d49f9c316cdbfe6c5d37f4345a1) Thanks [@hzblj](https://github.com/hzblj)! - The microphone can stop by itself: `listen({autoStop: {afterSilence, withoutSpeech}})` ends as `stop()` does once the user stops talking, or when nothing is said at all. `pause()` and `resume()` mute the microphone and hear it again (the state is `paused` meanwhile), with the recording and the times kept in step. `voiceProcessing` is now a shared listen option and works on Android too, with the platform's echo canceler and noise suppressor; it moved out of `ios`.

  `onDevice` is `'required'` (the default, as `true` was), `'preferred'` or `'off'` (as `false` was). `preferred` answers on the first run without waiting for a model download: iOS 26 uses Apple's servers until the model, downloading in the background, is installed, and Android the default recognizer until the on-device model is there.

## 0.1.5

### Patch Changes

- [`acb369b`](https://github.com/hzblj/expo-speech/commit/acb369b39e6cb978a73023c81189d280245c9c35) Thanks [@hzblj](https://github.com/hzblj)! - The README shows the example app on iOS and Android.

## 0.1.4

### Patch Changes

- [`31c0dc0`](https://github.com/hzblj/expo-speech/commit/31c0dc06073bb5490a0af1a537b4c9dac4998714) Thanks [@hzblj](https://github.com/hzblj)! - The LICENSE is the complete MIT license, with the limitation of liability it was missing.

## 0.1.3

### Patch Changes

- [`8d54647`](https://github.com/hzblj/expo-speech/commit/8d54647b9ee8589d603a66e0b9fef2691445dbf4) Thanks [@hzblj](https://github.com/hzblj)! - iOS: in the Simulator, a speech model it cannot download or run now fails as `unsupported`, saying that speech recognition is unsupported in this simulator and to transcribe on a device, instead of `locale-unavailable` ("assistant.en_GB asset unavailable after attempted download") or "No audio format suits the speech models". The iOS 26.5 and 27.0 simulator runtimes cannot transcribe; a device downloads the same model and does.

## 0.1.2

### Patch Changes

- [`32c6fd9`](https://github.com/hzblj/expo-speech/commit/32c6fd9574c4092909d16bfb748fb931734183ac) Thanks [@hzblj](https://github.com/hzblj)! - The README links to the other libraries, at libraries.janblazej.dev.

## 0.1.1

### Patch Changes

- [`17e5026`](https://github.com/hzblj/expo-speech/commit/17e5026be0dcfe44ecc07da4fe36226f26604a5a) Thanks [@hzblj](https://github.com/hzblj)! - The last word lets go once it has been said: `useTranscriptPlayback` (and `PlaybackFollower`) report the number of words then, so `TranscriptText` shows every word as spoken and none as active, instead of keeping the last one lit after the audio ends. `segmentIndex` does the same with segments.
