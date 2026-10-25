# @hzblj/expo-speech

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
