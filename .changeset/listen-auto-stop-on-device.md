---
"@hzblj/expo-speech": minor
---

The microphone can stop by itself: `listen({autoStop: {afterSilence, withoutSpeech}})` ends as `stop()` does once the user stops talking, or when nothing is said at all. `pause()` and `resume()` mute the microphone and hear it again (the state is `paused` meanwhile), with the recording and the times kept in step. `voiceProcessing` is now a shared listen option and works on Android too, with the platform's echo canceler and noise suppressor; it moved out of `ios`.

`onDevice` is `'required'` (the default, as `true` was), `'preferred'` or `'off'` (as `false` was). `preferred` answers on the first run without waiting for a model download: iOS 26 uses Apple's servers until the model, downloading in the background, is installed, and Android the default recognizer until the on-device model is there.
