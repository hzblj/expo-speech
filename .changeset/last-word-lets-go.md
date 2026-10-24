---
'@hzblj/expo-speech': patch
---

The last word lets go once it has been said: `useTranscriptPlayback` (and `PlaybackFollower`) report the number of words then, so `TranscriptText` shows every word as spoken and none as active, instead of keeping the last one lit after the audio ends. `segmentIndex` does the same with segments.
