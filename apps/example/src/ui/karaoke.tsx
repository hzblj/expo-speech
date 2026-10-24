import type {Transcript} from '@hzblj/expo-speech'
import {type ColorToken, Island, RnText, Text} from '@hzblj/kara-ui'
import {useMemo} from 'react'

type KaraokeProps = {
  transcript: Pick<Transcript, 'text' | 'segments'>
  /** The word being said; -1 (or unset) when nothing plays, and every word reads plainly. */
  wordIndex?: number
  playing?: boolean
  variant?: 'body' | 'headline' | 'headingS'
}

/** A run of the transcript: a word and what follows it up to the next, or the text before the first word. */
type Piece = {index: number; text: string; volatile: boolean}

const piecesOf = (transcript: KaraokeProps['transcript']): Piece[] => {
  const pieces: Piece[] = []
  let cursor = 0
  let index = 0

  for (const segment of transcript.segments) {
    for (const word of segment.words) {
      if (word.range[0] > cursor) {
        const gap = transcript.text.slice(cursor, word.range[0])
        const previous = pieces[pieces.length - 1]
        if (previous) {
          previous.text += gap
        } else {
          pieces.push({index: -1, text: gap, volatile: !segment.isFinal})
        }
      }
      pieces.push({index, text: transcript.text.slice(word.range[0], word.range[1]), volatile: !segment.isFinal})
      cursor = word.range[1]
      index += 1
    }
  }

  const rest = transcript.text.slice(cursor)
  const last = pieces[pieces.length - 1]
  if (rest && last) {
    last.text += rest
  }
  return pieces
}

/**
 * A transcript lit word by word as it plays, Lapz style, natively: one kara `Text` with a span per word and `animate`,
 * so each word eases from dimmed, to the accent while it is said, to full colour once said. Text the recognizer may
 * still revise stays dimmed.
 */
export const Karaoke = ({playing = false, transcript, variant = 'body', wordIndex = -1}: KaraokeProps) => {
  const pieces = useMemo(() => piecesOf(transcript), [transcript])
  const following = playing || wordIndex >= 0

  const colorOf = (piece: Piece): ColorToken => {
    if (piece.volatile) {
      return 'content.tertiary'
    }
    if (!following || piece.index < wordIndex) {
      return 'content.primary'
    }
    return piece.index === wordIndex ? 'content.accent' : 'content.tertiary'
  }

  return (
    <Island>
      <Text align="left" animate color="content.primary" variant={variant} wide>
        {pieces.map(piece => (
          <Text color={colorOf(piece)} key={`${piece.index}:${piece.text}`}>
            {piece.text}
          </Text>
        ))}
      </Text>
    </Island>
  )
}

/** `0:19`. */
export const formatDuration = (seconds: number | null | undefined) => {
  if (seconds == null || !Number.isFinite(seconds)) {
    return '0:00'
  }
  const whole = Math.max(0, Math.round(seconds))
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`
}

export const Caption = ({children, color = 'content.secondary'}: {children: string; color?: ColorToken}) => (
  <RnText color={color} style={{letterSpacing: 0.6}} variant="captionMedium">
    {children.toUpperCase()}
  </RnText>
)
