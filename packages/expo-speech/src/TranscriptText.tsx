import {useCallback, useMemo, useRef} from 'react'
import {type StyleProp, Text, type TextProps, type TextStyle} from 'react-native'

import type {Transcript, TranscriptWord} from './types'

export type TranscriptTextProps = Omit<TextProps, 'children'> & {
  transcript: Pick<Transcript, 'text' | 'segments'>
  /**
   * The word being said, from `useTranscriptPlayback`. Words before it are spoken, words after it upcoming. Unset (or
   * -1) leaves every word upcoming.
   */
  wordIndex?: number
  /** Words already said. */
  spokenWordStyle?: StyleProp<TextStyle>
  /** The word being said. */
  activeWordStyle?: StyleProp<TextStyle>
  /** Words not said yet. */
  upcomingWordStyle?: StyleProp<TextStyle>
  /** Text the recognizer may still revise. */
  volatileStyle?: StyleProp<TextStyle>
  /** A word was pressed: seek the player to `word.start`, for one. */
  onWordPress?: (word: TranscriptWord, index: number) => void
}

/** A stretch of the text: a word (with its index among the words) or what lies between words. */
type Piece = {text: string; index: number; volatile: boolean}

type WordState = 'spoken' | 'active' | 'upcoming'

/** Consecutive pieces that look the same, rendered as one span. */
type Group = {key: string; state: WordState; volatile: boolean; pieces: Piece[]}

const pieceState = (piece: Piece, previous: WordState, wordIndex: number): WordState => {
  if (piece.index < 0) {
    // Between words: like the word before, so the active word's highlight doesn't spill onto the space after it.
    return previous === 'active' ? 'upcoming' : previous
  }
  return piece.index < wordIndex ? 'spoken' : piece.index === wordIndex ? 'active' : 'upcoming'
}

/**
 * A transcript as one paragraph of text whose words take a style by where playback is: spoken, active or upcoming.
 * Karaoke captions, in short.
 *
 * Words that look the same share one span, so a long transcript stays a handful of spans: Android styles at most 255
 * span operations per text. With `onWordPress`, each word is a span of its own inside them, unstyled, to be pressed.
 */
export const TranscriptText = ({
  activeWordStyle,
  onWordPress,
  spokenWordStyle,
  transcript,
  upcomingWordStyle,
  volatileStyle,
  wordIndex = -1,
  ...props
}: TranscriptTextProps) => {
  const pieces = useMemo(() => {
    const result: Piece[] = []
    let cursor = 0
    let index = 0

    for (const segment of transcript.segments) {
      const volatile = !segment.isFinal

      for (const word of segment.words) {
        if (word.range[0] > cursor) {
          result.push({index: -1, text: transcript.text.slice(cursor, word.range[0]), volatile})
        }
        result.push({index, text: transcript.text.slice(word.range[0], word.range[1]), volatile})
        cursor = word.range[1]
        index += 1
      }

      if (segment.range[1] > cursor) {
        result.push({index: -1, text: transcript.text.slice(cursor, segment.range[1]), volatile})
        cursor = segment.range[1]
      }
    }

    return result
  }, [transcript])

  const words = useMemo(() => transcript.segments.flatMap(segment => segment.words), [transcript])

  const groups = useMemo(() => {
    const result: Group[] = []
    let previous: WordState = wordIndex >= 0 ? 'spoken' : 'upcoming'

    for (const [position, piece] of pieces.entries()) {
      const state = pieceState(piece, previous, wordIndex)
      const last = result[result.length - 1]

      if (last && last.state === state && last.volatile === piece.volatile) {
        last.pieces.push(piece)
      } else {
        result.push({key: `${position}`, pieces: [piece], state, volatile: piece.volatile})
      }
      previous = state
    }

    return result
  }, [pieces, wordIndex])

  const styles = useMemo(
    () => ({active: activeWordStyle, spoken: spokenWordStyle, upcoming: upcomingWordStyle, volatile: volatileStyle}),
    [activeWordStyle, spokenWordStyle, upcomingWordStyle, volatileStyle]
  )

  const latest = useRef({onWordPress, words})

  latest.current = {onWordPress, words}

  const press = useCallback((index: number) => {
    const word = latest.current.words[index]

    if (word) {
      latest.current.onWordPress?.(word, index)
    }
  }, [])

  return (
    <Text {...props}>
      {groups.map(group => (
        <Text key={group.key} style={[styles[group.state], group.volatile && styles.volatile]}>
          {onWordPress
            ? group.pieces.map((piece, position) =>
                piece.index >= 0 ? (
                  <Text key={position} onPress={() => press(piece.index)}>
                    {piece.text}
                  </Text>
                ) : (
                  piece.text
                )
              )
            : group.pieces.map(piece => piece.text).join('')}
        </Text>
      ))}
    </Text>
  )
}
