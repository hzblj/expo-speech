---
"@hzblj/expo-speech": minor
---

Native code can follow a transcription's microphone without JavaScript: the root mean square of every 80 ms of audio, as the `expo.audioLevel` notification on iOS (the transcription is the object) and through `addAudioLevelListener` on Android. `@hzblj/expo-waveform`'s `LiveWaveformView` draws it live as its `meter`.
