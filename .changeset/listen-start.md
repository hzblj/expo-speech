---
"@hzblj/expo-speech": minor
---

Listening never hangs and says why it did not start. A microphone transcription is `preparing` until the microphone opens and `transcribing` from then on; `stop()` or `cancel()` before it opens ends it as `cancelled` at once and frees the queue; and the new `startTimeout` option (10 s by default) fails it as `start-timeout`, with a message that says what it waited for. With `onDevice: 'preferred'` on iOS 26, an analyzer that has not opened the microphone within 4 seconds, or failed before it did, hands it to `SFSpeechRecognizer`. In the iOS Simulator, `preferred` uses Apple's servers and no longer installs a model the Simulator cannot run.
