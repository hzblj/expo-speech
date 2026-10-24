import {useReleasingSharedObject} from 'expo-modules-core'
import {useEffect, useRef, useState} from 'react'

import {ExpoSpeech, type SpeechTranscriber, type Transcription} from './ExpoSpeechModule'
import {followPlayer, PlaybackFollower, type PlaybackSource} from './playback'
import {applyTranscriptUpdate, emptyTranscript, indexAt} from './transcript'
import type {
  SpeechError,
  SpeechSource,
  SpeechTranscriberOptions,
  TranscribeOptions,
  Transcript,
  TranscriptionEvents,
  TranscriptionState,
  TranscriptSegment,
  TranscriptWord,
} from './types'

/**
 * A transcriber for these options, released when the component unmounts or the options change. Keep the options
 * stable (or memoized): any change makes a new transcriber.
 */
export const useSpeechTranscriber = (options: SpeechTranscriberOptions = {}): SpeechTranscriber =>
  useReleasingSharedObject(() => new ExpoSpeech.SpeechTranscriber(options), [JSON.stringify(options)])

type LanguageEvent = Parameters<TranscriptionEvents['language']>[0]

export type TranscriptionSnapshot = {
  transcript: Transcript
  state: TranscriptionState | null
  /** From 0 to 1: download, then analysis. */
  progress: number
  progressPhase: 'installing' | 'downloading' | 'transcribing' | null
  error: SpeechError | null
  /** Whether speech is being heard now, with `detectSpeech`. */
  speaking: boolean
  /** The microphone's last level in dBFS, with `volumeInterval`. */
  level: number | null
  /** Android 14: the last detected language. */
  language: LanguageEvent | null
  fromCache: boolean
}

const idle: TranscriptionSnapshot = {
  error: null,
  fromCache: false,
  language: null,
  level: null,
  progress: 0,
  progressPhase: null,
  speaking: false,
  state: null,
  transcript: emptyTranscript(),
}

const snapshotOf = (transcription: Transcription | null): TranscriptionSnapshot =>
  transcription
    ? {
        ...idle,
        error: transcription.error,
        fromCache: transcription.fromCache,
        progress: transcription.progress,
        state: transcription.state,
        transcript: transcription.transcript,
      }
    : idle

const SETTLED: TranscriptionState[] = ['completed', 'cancelled', 'failed']

/**
 * Follows a transcription as it runs: the transcript with its volatile tail, the state, progress, speech and level.
 * Re-renders on every change; `null` gives an idle snapshot.
 */
export const useTranscription = (transcription: Transcription | null): TranscriptionSnapshot => {
  const [snapshot, setSnapshot] = useState(() => snapshotOf(transcription))

  useEffect(() => {
    const initial = snapshotOf(transcription)
    let transcript = initial.transcript

    setSnapshot(initial)

    if (!transcription) {
      return
    }

    const set = (patch: Partial<TranscriptionSnapshot>) => setSnapshot(current => ({...current, ...patch}))

    const subscriptions = [
      transcription.addListener('update', update => {
        transcript = applyTranscriptUpdate(transcript, update) ?? transcription.transcript
        set({transcript})
      }),
      transcription.addListener('stateChange', ({error, state}) => {
        if (SETTLED.includes(state)) {
          transcript = transcription.transcript
          set({error, fromCache: transcription.fromCache, speaking: false, state, transcript})
        } else {
          set({error, state})
        }
      }),
      transcription.addListener('progress', ({fraction, phase}) => set({progress: fraction, progressPhase: phase})),
      transcription.addListener('speech', ({detected}) => set({speaking: detected})),
      transcription.addListener('volume', ({level}) => set({level})),
      transcription.addListener('language', language => set({language})),
    ]

    // A transcription that settled between the snapshot and the subscriptions sent its events to nobody.
    if (transcription.state !== initial.state) {
      transcript = transcription.transcript
      set(snapshotOf(transcription))
    }

    return () => {
      for (const subscription of subscriptions) {
        subscription.remove()
      }
    }
  }, [transcription])

  return snapshot
}

export type UseTranscribeOptions = TranscribeOptions & {
  /**
   * Start only when true, for a list that transcribes what is on screen.
   * @default true
   */
  enabled?: boolean
  /**
   * Take the transcription out of the queue when the component unmounts before it starts. One that is running is
   * left to finish, so its transcript lands in the cache.
   * @default true
   */
  cancelOnUnmount?: boolean
}

/**
 * Transcribes a source with the transcriber and follows it. With a `cacheKey`, the same audio is transcribed once,
 * however many components ask for it, and comes from the cache afterwards.
 */
export const useTranscribe = (
  transcriber: SpeechTranscriber | null,
  source: SpeechSource | null | undefined,
  {cancelOnUnmount = true, enabled = true, ...options}: UseTranscribeOptions = {}
): TranscriptionSnapshot & {transcription: Transcription | null} => {
  const [transcription, setTranscription] = useState<Transcription | null>(null)
  // Compared by value: an inline source object or options literal is a new object on every render.
  const sourceKey = JSON.stringify(source ?? null)
  const optionsKey = JSON.stringify(options)

  useEffect(() => {
    const currentSource = JSON.parse(sourceKey) as SpeechSource | null

    if (!transcriber || currentSource == null || !enabled) {
      setTranscription(null)
      return
    }

    const started = transcriber.transcribe(currentSource, JSON.parse(optionsKey) as TranscribeOptions)

    setTranscription(started)

    return () => {
      if (cancelOnUnmount && started.state === 'queued') {
        started.cancel()
      }
    }
  }, [transcriber, sourceKey, optionsKey, enabled, cancelOnUnmount])

  return {...useTranscription(transcription), transcription}
}

export type TranscriptPlayback = {
  /** The word being said (or last said), or -1 before the first. */
  wordIndex: number
  word: TranscriptWord | null
  segmentIndex: number
  segment: TranscriptSegment | null
  /** The player's time when the word changed. */
  time: number
  /** The player's time now, reckoned between its reports. */
  getTime(): number
}

/**
 * The word being said while a player plays the transcribed audio: expo-audio's `AudioPlayer` or expo-video's
 * `VideoPlayer`. Re-renders only when the word changes, on time to the millisecond, without polling the player.
 */
export const useTranscriptPlayback = (
  transcript: Pick<Transcript, 'words' | 'segments'> | null,
  player: PlaybackSource | null,
  {offset = 0}: {offset?: number} = {}
): TranscriptPlayback => {
  const [state, setState] = useState({index: -1, time: 0})
  const follower = useRef<PlaybackFollower | null>(null)
  const words = transcript?.words
  const latestWords = useRef(words)

  latestWords.current = words

  useEffect(() => {
    if (!player) {
      setState({index: -1, time: 0})
      return
    }

    const current = new PlaybackFollower(latestWords.current ?? [], (index, time) => setState({index, time}), {
      offset,
    })
    const unsubscribe = followPlayer(player, current)

    follower.current = current

    return () => {
      unsubscribe()
      current.dispose()
      follower.current = null
    }
  }, [player, offset])

  useEffect(() => {
    follower.current?.setItems(words ?? [])
  }, [words])

  const word = words?.[state.index] ?? null
  const segmentIndex = word && transcript ? indexAt(transcript.segments, word.start) : -1

  return {
    getTime: () => (follower.current?.time ?? 0) + offset,
    segment: transcript?.segments[segmentIndex] ?? null,
    segmentIndex,
    time: state.time,
    word,
    wordIndex: word ? state.index : -1,
  }
}
