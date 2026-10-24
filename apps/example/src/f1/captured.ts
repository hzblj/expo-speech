import type {Transcript, TranscriptionSnapshot} from '@hzblj/expo-speech'
import * as Device from 'expo-device'
import {Platform} from 'react-native'

import transcripts from './transcripts.json'

/**
 * The weekend's transcripts as `SpeechAnalyzer` makes them on the Mac (`yarn transcripts`, `scripts/transcripts`):
 * expo-speech's own engine, the one iOS 26 runs. The iOS Simulator cannot get or run Apple's speech models, so there,
 * and only there, a message whose transcription fails shows its transcript from here, the way a device shows its own.
 */
const CAPTURED = Platform.OS === 'ios' && !Device.isDevice ? (transcripts as unknown as Record<string, Transcript>) : {}

/** A transcription as the screen should show it: on the iOS Simulator, a failed one gives way to the Mac's. */
export const withCaptured = <T extends Pick<TranscriptionSnapshot, 'state' | 'transcript'>>(
  url: string,
  snapshot: T
): T => {
  const captured = snapshot.state === 'failed' ? CAPTURED[url] : undefined

  return captured ? {...snapshot, error: null, state: 'completed', transcript: captured} : snapshot
}
