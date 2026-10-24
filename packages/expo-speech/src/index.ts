import './transcriber'

import {ExpoSpeech, type SpeechTranscriber as SpeechTranscriberInstance} from './ExpoSpeechModule'

/** A recognizer for one locale and configuration: `new SpeechTranscriber(options)`, or `useSpeechTranscriber`. */
export const SpeechTranscriber = ExpoSpeech.SpeechTranscriber
export type SpeechTranscriber = SpeechTranscriberInstance
export type {Transcription} from './ExpoSpeechModule'
export {
  type TranscriptionSnapshot,
  type TranscriptPlayback,
  type UseTranscribeOptions,
  useSpeechTranscriber,
  useTranscribe,
  useTranscription,
  useTranscriptPlayback,
} from './hooks'
export {followPlayer, PlaybackFollower, type PlaybackFollowerOptions, type PlaybackSource} from './playback'
export {type PermissionOptions, Speech} from './Speech'
export {TranscriptText, type TranscriptTextProps} from './TranscriptText'
export {
  applyTranscriptUpdate,
  emptyTranscript,
  finalTranscript,
  isWordActive,
  type SubtitleOptions,
  segmentIndexAt,
  toSRT,
  toWebVTT,
  wordIndexAt,
} from './transcript'
export type * from './types'
