import {memo, useCallback, useMemo, useRef} from 'react'
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

type Piece = {text: string; word: TranscriptWord | null; index: number; volatile: boolean}

type WordState = 'spoken' | 'active' | 'upcoming'

type WordProps = {
  text: string
  index: number
  state: WordState
  volatile: boolean
  styles: Record<WordState | 'volatile', StyleProp<TextStyle>>
  onPress: ((index: number) => void) | null
}

const Word = memo(({index, onPress, state, styles, text, volatile}: WordProps) => (
  <Text onPress={onPress ? () => onPress(index) : undefined} style={[styles[state], volatile && styles.volatile]}>
    {text}
  </Text>
))

/**
 * A transcript as one paragraph of text whose words take a style by where playback is: spoken, active or upcoming.
 * Karaoke captions, in short. Only the words whose state changes re-render.
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
          result.push({index: -1, text: transcript.text.slice(cursor, word.range[0]), volatile, word: null})
        }

        result.push({index, text: word.text, volatile, word})
        cursor = word.range[1]
        index += 1
      }

      if (segment.range[1] > cursor) {
        result.push({index: -1, text: transcript.text.slice(cursor, segment.range[1]), volatile, word: null})
        cursor = segment.range[1]
      }
    }

    return result
  }, [transcript])

  const styles = useMemo(
    () => ({active: activeWordStyle, spoken: spokenWordStyle, upcoming: upcomingWordStyle, volatile: volatileStyle}),
    [activeWordStyle, spokenWordStyle, upcomingWordStyle, volatileStyle]
  )

  const latest = useRef({onWordPress, pieces})

  latest.current = {onWordPress, pieces}

  const onPress = useCallback((index: number) => {
    const piece = latest.current.pieces.find(candidate => candidate.index === index)

    if (piece?.word) {
      latest.current.onWordPress?.(piece.word, index)
    }
  }, [])

  return (
    <Text {...props}>
      {pieces.map((piece, position) =>
        piece.word ? (
          <Word
            index={piece.index}
            key={position}
            onPress={onWordPress ? onPress : null}
            state={piece.index < wordIndex ? 'spoken' : piece.index === wordIndex ? 'active' : 'upcoming'}
            styles={styles}
            text={piece.text}
            volatile={piece.volatile}
          />
        ) : (
          piece.text
        )
      )}
    </Text>
  )
}
