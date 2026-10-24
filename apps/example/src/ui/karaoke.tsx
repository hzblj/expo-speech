import {type Transcript, TranscriptText, type TranscriptWord} from '@hzblj/expo-speech'
import {Box, type ColorToken, RnText, useAppTheme} from '@hzblj/kara-ui'
import {useMemo} from 'react'

type KaraokeProps = {
  transcript: Pick<Transcript, 'text' | 'segments'>
  /** The word being said; -1 (or unset) when nothing plays, and every word reads plainly. */
  wordIndex?: number
  playing?: boolean
  variant?: 'body' | 'headline' | 'headingS'
  onWordPress?: (word: TranscriptWord, index: number) => void
}

/**
 * A transcript lit word by word as it plays, Lapz style: what was said in full colour, the word being said in the
 * accent, what is coming dimmed. Text the recognizer may still revise is dimmed too.
 */
export const Karaoke = ({onWordPress, playing = false, transcript, variant = 'body', wordIndex = -1}: KaraokeProps) => {
  const theme = useAppTheme()
  const styles = useMemo(
    () => ({
      active: {color: theme.color('content.accent')},
      spoken: {color: theme.color('content.primary')},
      upcoming: {color: theme.color(playing ? 'content.tertiary' : 'content.primary')},
      volatile: {opacity: 0.55},
    }),
    [theme, playing]
  )
  const typography = theme.typography[variant]

  return (
    <TranscriptText
      activeWordStyle={styles.active}
      onWordPress={onWordPress}
      spokenWordStyle={styles.spoken}
      style={{fontSize: typography.fontSize, lineHeight: typography.lineHeight}}
      transcript={transcript}
      upcomingWordStyle={styles.upcoming}
      volatileStyle={styles.volatile}
      wordIndex={playing || wordIndex >= 0 ? wordIndex : -1}
    />
  )
}

type WordTrackProps = {
  words: TranscriptWord[]
  duration: number
  time: number
  color?: ColorToken
}

/** The player's track with a tick where every word starts, filled up to the playhead. */
export const WordTrack = ({color = 'content.accent', duration, time, words}: WordTrackProps) => {
  const theme = useAppTheme()
  const progress = duration > 0 ? Math.min(1, Math.max(0, time / duration)) : 0

  return (
    <Box h={14} justify="center" wide>
      <Box bg="fill.quaternary" borderRadius="full" h={4} overflow="hidden" wide>
        <Box h={4} style={{backgroundColor: theme.color(color), width: `${progress * 100}%`}} />
      </Box>
      {duration > 0
        ? words.map(word => (
            <Box
              key={`${word.range[0]}`}
              position="absolute"
              style={{
                backgroundColor: theme.color(word.start <= time ? color : 'content.tertiary'),
                height: 10,
                left: `${(word.start / duration) * 100}%`,
                top: 2,
                width: 1.5,
              }}
            />
          ))
        : null}
    </Box>
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
