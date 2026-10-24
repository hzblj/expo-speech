---
'@hzblj/expo-speech': patch
---

iOS: in the Simulator, a speech model it cannot download or run now fails as `unsupported`, saying that speech recognition is unsupported in this simulator and to transcribe on a device, instead of `locale-unavailable` ("assistant.en_GB asset unavailable after attempted download") or "No audio format suits the speech models". The iOS 26.5 and 27.0 simulator runtimes cannot transcribe; a device downloads the same model and does.
