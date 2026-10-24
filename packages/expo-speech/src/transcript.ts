import type {Transcript, TranscriptSegment, TranscriptWord} from './types'

export const emptyTranscript = (locale = ''): Transcript => ({
  audioUri: null,
  duration: null,
  locale,
  segments: [],
  text: '',
  words: [],
})

const finalTextLength = (segments: TranscriptSegment[]) =>
  segments.reduce((length, segment) => (segment.isFinal ? length + segment.text.length : length), 0)

/** The transcript with these segments: `text` and `words` follow from them. */
export const withSegments = (transcript: Transcript, segments: TranscriptSegment[]): Transcript => ({
  ...transcript,
  segments,
  text: segments.map(segment => segment.text).join(''),
  words: segments.flatMap(segment => segment.words),
})

/**
 * Applies an `update` event: appends its final segments and replaces the volatile one. Returns `null` when the update
 * does not continue this transcript (an update was missed), and the caller should read the transcript again.
 */
export const applyTranscriptUpdate = (
  transcript: Transcript,
  update: {segments: TranscriptSegment[]; volatile: TranscriptSegment | null}
): Transcript | null => {
  const finals = transcript.segments.filter(segment => segment.isFinal)
  let length = finalTextLength(finals)

  for (const segment of update.segments) {
    if (segment.range[1] <= length) {
      // Already here: the update raced the snapshot it is applied to.
      continue
    }

    if (segment.range[0] !== length) {
      return null
    }

    finals.push(segment)
    length = segment.range[1]
  }

  if (update.volatile && update.volatile.range[0] !== length) {
    return null
  }

  return withSegments(transcript, update.volatile ? [...finals, update.volatile] : finals)
}

/** The final part only: the transcript without its volatile tail. */
export const finalTranscript = (transcript: Transcript): Transcript =>
  withSegments(
    transcript,
    transcript.segments.filter(segment => segment.isFinal)
  )

/**
 * The index of the last item that has started by `time`, or -1 before the first. Items must be in time order, as a
 * transcript's words and segments are.
 */
export const indexAt = (items: readonly {start: number}[], time: number): number => {
  let low = 0
  let high = items.length - 1
  let found = -1

  while (low <= high) {
    const middle = (low + high) >> 1

    if ((items[middle]?.start ?? Number.POSITIVE_INFINITY) <= time) {
      found = middle
      low = middle + 1
    } else {
      high = middle - 1
    }
  }

  return found
}

/** The index of the word being said at `time` (or the last one said before it), or -1 before the first. */
export const wordIndexAt = (transcript: Pick<Transcript, 'words'>, time: number) => indexAt(transcript.words, time)

/** The index of the segment at `time` (or the last one before it), or -1 before the first. */
export const segmentIndexAt = (transcript: Pick<Transcript, 'segments'>, time: number) =>
  indexAt(transcript.segments, time)

/** Whether `time` falls inside the word, between its start and its end. */
export const isWordActive = (word: TranscriptWord, time: number) => word.start <= time && time < word.end

export type SubtitleOptions = {
  /**
   * The longest cue, in characters. Longer segments are split between words.
   * @default 84
   */
  maxCharacters?: number
  /**
   * The longest cue, in seconds.
   * @default 7
   */
  maxDuration?: number
}

type Cue = {start: number; end: number; text: string}

const cuesOf = (transcript: Transcript, {maxCharacters = 84, maxDuration = 7}: SubtitleOptions): Cue[] => {
  const cues: Cue[] = []

  for (const segment of transcript.segments) {
    if (!segment.isFinal) {
      continue
    }

    if (segment.words.length === 0) {
      const text = segment.text.trim()

      if (text) {
        cues.push({end: segment.end, start: segment.start, text})
      }

      continue
    }

    let cue: Cue | null = null

    for (const word of segment.words) {
      const next: string = cue ? `${cue.text} ${word.text}` : word.text

      if (cue && (next.length > maxCharacters || word.end - cue.start > maxDuration)) {
        cues.push(cue)
        cue = null
      }

      cue = cue
        ? {end: word.end, start: cue.start, text: `${cue.text} ${word.text}`}
        : {end: word.end, start: word.start, text: word.text}
    }

    if (cue) {
      cues.push(cue)
    }
  }

  return cues
}

const timestamp = (seconds: number, separator: '.' | ',') => {
  const milliseconds = Math.max(0, Math.round(seconds * 1000))
  const pad = (value: number, length = 2) => String(value).padStart(length, '0')

  return `${pad(Math.floor(milliseconds / 3_600_000))}:${pad(Math.floor(milliseconds / 60_000) % 60)}:${pad(
    Math.floor(milliseconds / 1000) % 60
  )}${separator}${pad(milliseconds % 1000, 3)}`
}

/** The final segments as WebVTT subtitles. */
export const toWebVTT = (transcript: Transcript, options: SubtitleOptions = {}) =>
  [
    'WEBVTT',
    ...cuesOf(transcript, options).map(
      cue => `${timestamp(cue.start, '.')} --> ${timestamp(cue.end, '.')}\n${cue.text}`
    ),
  ].join('\n\n') + '\n'

/** The final segments as SubRip (SRT) subtitles. */
export const toSRT = (transcript: Transcript, options: SubtitleOptions = {}) =>
  cuesOf(transcript, options)
    .map((cue, index) => `${index + 1}\n${timestamp(cue.start, ',')} --> ${timestamp(cue.end, ',')}\n${cue.text}`)
    .join('\n\n') + '\n'
