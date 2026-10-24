# example

The example app for `@hzblj/expo-speech`, in the style of Lapz: Formula 1 team radio, transcribed on the device and
played back with its words lit. Built from `@hzblj/kara-ui` like every hzblj example. Private; never published.

| Path | What it is |
| --- | --- |
| `app/(tabs)/` | Native tabs (`Tabs` from `@hzblj/kara-ui/router`), each a stack with a large title: Radio, Pit wall, Lab, Languages. Route files only re-export a screen from `src/`. |
| `src/radio/` | The latest weekend's sessions and their team radio, newest first: a card per message, transcribed as it comes on screen (`useTranscribe` with the recording URL as `cacheKey`), played inline through one shared expo-audio player with `Karaoke` and `WordTrack`. |
| `src/live/` | Hold to talk: `listen({record: true})`, the level as a ring, the live text, then the recording played back with its words lit. |
| `src/lab/` | Every option against one message, transcribed fresh: segments, confidence, alternatives, each word's time, WebVTT and SRT. |
| `src/languages/` | What the engine can do here, and the locales: installed first, the rest downloadable with progress. |
| `src/f1/` | OpenF1 (`openf1.ts`: sessions, meetings, drivers, team radio, cached per path for the app's lifetime) and the clips of a session (`radio-clips.ts`). |
| `src/speech.ts` | The radio transcriber: British English, the session's driver names and pit wall jargon as contextual strings. |
| `src/ui/` | `Page`, `Section`, `TabStack`, and `karaoke.tsx` (`Karaoke`, `WordTrack`, `Caption`, `formatDuration`). |
| `assets/icons/` | Material Symbols SVGs, turned into native assets by kara's plugin at prebuild. |

**No Formula 1 media in the repo.** The recordings, headshots and session data come from OpenF1 and formula1.com while
the app runs; nothing of theirs is committed.

**Native changes need a rebuild**: `yarn prebuild` (it builds the package's config plugin first), then a native run.
On the iOS 26.0 simulator `SpeechTranscriber` is unavailable and the package falls back to `DictationTranscriber`.
