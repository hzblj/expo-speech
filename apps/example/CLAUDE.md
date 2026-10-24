# example

The example app for `@hzblj/expo-speech`, in the style of Lapz: Formula 1 team radio, transcribed on the device and
played back with its words lit. Built from `@hzblj/kara-ui` like every hzblj example. Private; never published.

| Path | What it is |
| --- | --- |
| `app/(tabs)/` | Native tabs (`Tabs` from `@hzblj/kara-ui/router`), each a stack with a large title: Radio, Pit wall, Lab, Languages. Route files only re-export a screen from `src/`. |
| `src/radio/` | The weekend's sessions as chips and their team radio, newest first: a card per message, transcribed as it comes on screen (`useTranscribe` with the recording URL as `cacheKey`), played inline through one shared expo-audio player: a play button, the recording as a seekable `WaveformView` (`@hzblj/expo-waveform`) with a tick where every word starts, and `Karaoke` (one Kara `Text`, a span per word, `animate`). |
| `src/live/` | Hold to talk: `listen({record: true})`, the level as a ring, the live text, then the recording played back with its words lit. |
| `src/lab/` | Every option against one message, transcribed fresh: segments, confidence, alternatives, each word's time, WebVTT and SRT. |
| `src/languages/` | What the engine can do here, and the locales: installed first, the rest downloadable with progress. |
| `src/f1/` | `radio.json`, one weekend captured from OpenF1 by `scripts/radio.mjs`, and `radio.ts`, its sessions, clips and drivers. |
| `src/speech.ts` | The radio transcriber: British English, the session's driver names and pit wall jargon as contextual strings. |
| `src/ui/` | `Page`, `Section`, `TabStack`, `PlayButton`, and `karaoke.tsx` (`Karaoke`, `Caption`, `formatDuration`). |
| `assets/icons/` | Material Symbols SVGs, turned into native assets by kara's plugin at prebuild. |
| `assets/icon.png`, `assets/adaptive-icon.png` | The app icon: a speech bubble with a waveform, from plain shapes, on Formula 1 red (iOS); the bubble alone on `ICON_BACKGROUND` (Android). |

**Nothing asks OpenF1 while the app runs.** OpenF1 closes to the public during a live session (it answers 401 with a
link to buy a key, which must never reach the screen) and limits how often it is asked. The weekend is captured once
into `src/f1/radio.json` (`node scripts/radio.mjs 2025 "Abu Dhabi"`); to change it, run the script again when no session
is live. The recordings stream from Formula 1's own static files on livetiming.formula1.com, which stay open.

**No Formula 1 media in the repo.** The JSON holds names, numbers, times and URLs; the recordings and headshots load
from Formula 1 while the app runs; nothing of theirs is committed.

**Native changes need a rebuild**: `yarn prebuild` (it builds the package's config plugin first), then a native run.
On the iOS 26.0 simulator `SpeechTranscriber` is unavailable and the package falls back to `DictationTranscriber`.

**iOS 27 needs the scene life cycle.** Xcode 27's SDK asserts at launch on an app without `UIApplicationSceneManifest`,
which Expo 57's template lacks: `expo-build-properties` with `ios.enableSceneSupport` (in `app.config.ts`) starts React
Native in Expo's scene delegate instead.

**Captures start playback by link.** The iOS 27 simulator takes no scripted taps (`idb` cannot reach its HID), so
`speech-example:///?play=1` plays the selected session's second message, with the app in front (a link from outside asks
first). Status bar at 9:41 (`xcrun simctl status_bar … override`, Android's demo mode), Release builds.
